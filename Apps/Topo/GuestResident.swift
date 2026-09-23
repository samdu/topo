import Foundation
import TopoAuth
import TopoProxy
import TopoTurn
import TopoUserland
import UIKit

/// iOS's background time, from `UIApplication`.
@MainActor
final class ApplicationBackgroundTime: BackgroundTime {
    func begin(expiration: @escaping @MainActor () -> Void) -> Int {
        UIApplication.shared.beginBackgroundTask(withName: "zone.hexagon.topo.guest") {
            MainActor.assumeIsolated { expiration() }
        }.rawValue
    }

    func end(_ task: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task))
    }

    var remaining: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
}

/// The resident Claude Code on this phone: the guest booted once per process, the app's
/// `Documents/home` mounted as its home, the API proxy on loopback, and the one `GuestSession`,
/// carried through the app's lifecycle by a `GuestLifecycle` — started on the foreground, ended on
/// the way out once the grace is spent. The session id the next process resumes is kept in
/// `Documents/.guest-session`, beside the home. Nothing starts it in a user build: the chat still
/// answers through the Messages API, and only a debug launch (`DebugRun.guestTurn`) brings the
/// resident process up.
@MainActor
final class GuestResident {
    static let shared = GuestResident()

    private var starting: Task<GuestSession, Error>?
    private var lifecycle: GuestLifecycle?
    private var proxy: APIProxy?
    private var observers: [NSObjectProtocol] = []

    /// The app's `Documents/home`, mounted at `ClaudeLauncher.home`.
    static var homeDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("home", isDirectory: true)
    }

    static var sessionFile: SessionFile {
        SessionFile(url: URL.documentsDirectory.appendingPathComponent(".guest-session"))
    }

    /// Brings the guest and the session up, once per process, and starts following the app's
    /// lifecycle from the foreground it is in now. `tokens` is the app's one provider over the
    /// ordinary tokens; `log` hears the session's and the proxy's lines, and each way out's outcome.
    func start(tokens: StoredTokenProvider, userland: Userland = .shared,
               log: @escaping @Sendable (String) -> Void) async throws -> GuestSession {
        if let starting { return try await starting.value }
        let task = Task { @MainActor in
            _ = try await userland.bootGuest()
            let home = Self.homeDirectory
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Guest.shared.mount(home, at: ClaudeLauncher.home)
            let proxy = try APIProxy(log: { log("proxy: \($0)") })
            let port = try await proxy.start()
            self.proxy = proxy
            let credential = GuestCredential(store: KeychainTokenStore.guest, fallback: tokens)
            let launcher = ClaudeLauncher(model: ClaudeModel.pinned?.rawValue) {
                try await APIProxy.guestEnvironment(port: port, credential: credential).environment
            }
            let session = GuestSession(launcher: launcher, store: Self.sessionFile, log: log)
            let lifecycle = GuestLifecycle(session: session, time: ApplicationBackgroundTime(),
                                           report: { outcome in log("background: \(outcome)") })
            self.lifecycle = lifecycle
            self.follow(lifecycle)
            if UIApplication.shared.applicationState != .background { lifecycle.willEnterForeground() }
            return session
        }
        starting = task
        return try await task.value
    }

    private func follow(_ lifecycle: GuestLifecycle) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lifecycle.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lifecycle.willEnterForeground() }
            },
        ]
    }
}

#if DEBUG
extension DebugRun {
    static let guestTurnVariable = "TOPO_DEBUG_GUEST_TURN"
    /// What separates the turns in `TOPO_DEBUG_GUEST_TURN`.
    static let guestTurnSeparator = " || "

    /// The turns `TOPO_DEBUG_GUEST_TURN` names, in order, blank ones dropped.
    static func guestTurns(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let value = environment[guestTurnVariable] else { return [] }
        return value.components(separatedBy: guestTurnSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `TOPO_DEBUG_GUEST_TURN="<turn> || <turn> || …"`: on launch, bring the resident Claude Code up
    /// (`GuestResident`, the guest booted and Claude Code mounted as `TOPO_DEBUG_USERLAND` does,
    /// the proxy started, the home mounted) and send the turns to it one at a time, each once the
    /// app is in the foreground and the process is resident, printing each turn's model and
    /// session from its `system/init`, the tools it called, its reply and its wall time from send
    /// to result — or that it failed or was abandoned — and every lifecycle line: the start (fresh
    /// or resuming which session), each way out's outcome and the termination it confirmed.
    /// Nothing is sent twice: a turn abandoned at the teardown point is reported and the next
    /// turn goes on the next foreground. Ends in `guest turn done`. Nothing at all when the
    /// variable is absent; refused beside `TOPO_DEBUG_USERLAND`, since the resident's end ends
    /// every guest task.
    @MainActor
    static func guestTurn(tokens: StoredTokenProvider,
                          environment: [String: String] = ProcessInfo.processInfo.environment) async {
        let turns = guestTurns(environment)
        guard !turns.isEmpty else { return }
        // The resident's end is every guest task's, so nothing else may run in the guest beside it.
        if let command = environment[userlandVariable], !command.isEmpty {
            say("guest turn error: \(guestTurnVariable) and \(userlandVariable) are separate launches")
            say("guest turn done")
            return
        }
        say("guest: \(Userland.shared.summary)")
        do {
            let session = try await GuestResident.shared.start(tokens: tokens) { line in say("guest: \(line)") }
            for (index, text) in turns.enumerated() {
                let number = index + 1
                var updates: AsyncStream<GuestSession.TurnUpdate>?
                var sent = ContinuousClock.now
                while updates == nil {
                    try await residentInForeground(session)
                    sent = ContinuousClock.now
                    do {
                        updates = try await session.send(text)
                    } catch GuestSession.Refusal.notResident {
                        // Ended between the wait and the send: wait for the next one.
                        continue
                    }
                }
                // The process the turn went to, named on every line that says what took it, so a
                // run can hold that its turns all went to one resident process.
                let pid = await session.residentPID.map(String.init) ?? "none"
                say("guest turn \(number) sent: \(text)")
                guard let updates else { continue }
                for await update in updates {
                    switch update {
                    case .event(.started(let id, let model)):
                        say("guest turn \(number) model: \(model), session \(id), process \(pid)")
                    case .event(.toolUse(let name)):
                        say("guest turn \(number) tool: \(name)")
                    case .event(.malformed(let line)):
                        say("guest turn \(number) malformed line: \(line)")
                    case .event:
                        break
                    case .ended(let end):
                        let seconds = String(format: "%.2f", Double((ContinuousClock.now - sent) / .milliseconds(1)) / 1000)
                        switch end {
                        case .answered(let result):
                            say("guest turn \(number) answered in \(seconds) s: \(result.text ?? "")")
                        case .failed(let failure):
                            say("guest turn \(number) failed in \(seconds) s: \(failure)")
                        case .abandoned:
                            say("guest turn \(number) abandoned after \(seconds) s")
                        }
                    }
                }
            }
        } catch {
            say("guest turn error: \(error)")
        }
        say("guest turn done")
    }

    /// Waits until the app is in the foreground and the resident process is up.
    @MainActor
    private static func residentInForeground(_ session: GuestSession) async throws {
        while true {
            if UIApplication.shared.applicationState != .background {
                do {
                    try await session.ready()
                    return
                } catch GuestSession.Refusal.notResident {
                    // Went to the background while it was starting: wait for the next foreground.
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}
#endif
