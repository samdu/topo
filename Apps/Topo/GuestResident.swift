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
/// `Documents/.guest-session`, beside the home, and the bridge's ledger in
/// `Documents/.guest-bridge.json` beside that. The chat's harness brings it up
/// (`ResidentConversation`), once the userland is on the phone; so does a debug launch
/// (`DebugRun.guestTurn`).
@MainActor
final class GuestResident {
    static let shared = GuestResident()

    private let starting = StartOnce<GuestSession>()
    /// What of the start is done, so a start tried again after a failure does not do it twice.
    private var homeMounted = false
    private var proxyPort: UInt16?
    private var lifecycle: GuestLifecycle?
    private var proxy: APIProxy?
    private var observers: [NSObjectProtocol] = []

    /// The app's `Documents/home`, mounted at `ClaudeLauncher.home`.
    nonisolated static var homeDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("home", isDirectory: true)
    }

    nonisolated static var sessionFile: SessionFile {
        SessionFile(url: URL.documentsDirectory.appendingPathComponent(".guest-session"))
    }

    /// The bridge's ledger: what the guest has seen of the log, and the input outstanding.
    nonisolated static var ledgerFile: URL {
        URL.documentsDirectory.appendingPathComponent(".guest-bridge.json")
    }

    /// The session once `start` has made it, nil before.
    private(set) var session: GuestSession?

    /// The model a process is started with: the setting, as the debug pin makes it.
    static var model: String {
        let setting = UserDefaults.standard.string(forKey: Harness.modelKey).flatMap(ClaudeModel.init(rawValue:))
        return ClaudeModel.effective(setting ?? .default).rawValue
    }

    /// Brings the guest and the session up, once per process, and starts following the app's
    /// lifecycle from the foreground it is in now. A start that fails is not kept: the next call
    /// tries again from the step that failed (the kernel's own boot is once per process, and its
    /// answer is `Userland.bootGuest`'s to keep). `tokens` is the app's one provider over the
    /// ordinary tokens; `log` hears the session's and the proxy's lines, and each way out's outcome.
    func start(tokens: StoredTokenProvider, userland: Userland = .shared,
               log: @escaping @Sendable (String) -> Void) async throws -> GuestSession {
        try await starting.value { @MainActor in
            _ = try await userland.bootGuest()
            if !self.homeMounted {
                let home = Self.homeDirectory
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try Guest.shared.mount(home, at: ClaudeLauncher.home)
                self.homeMounted = true
            }
            let port: UInt16
            if let running = self.proxyPort {
                port = running
            } else {
                let proxy = try APIProxy(log: { log("proxy: \($0)") })
                do {
                    port = try await proxy.start()
                } catch {
                    await proxy.stop()
                    throw error
                }
                self.proxy = proxy
                self.proxyPort = port
            }
            let credential = GuestCredential(store: KeychainTokenStore.guest, fallback: tokens)
            let launcher = ClaudeLauncher {
                try await APIProxy.guestEnvironment(port: port, credential: credential).environment
            }
            let session = GuestSession(launcher: launcher, store: Self.sessionFile, model: Self.model, log: log)
            self.session = session
            let lifecycle = GuestLifecycle(session: session, time: ApplicationBackgroundTime(),
                                           report: { outcome in log("background: \(outcome)") })
            self.lifecycle = lifecycle
            self.follow(lifecycle)
            if UIApplication.shared.applicationState != .background { lifecycle.willEnterForeground() }
            return session
        }
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

/// One start at a time, whose success is kept and whose failure is not: every caller while a start
/// runs gets its answer, and a call after one that failed starts again.
@MainActor
final class StartOnce<Value: Sendable> {
    private var task: Task<Value, Error>?

    func value(_ start: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let task { return try await task.value }
        let task = Task { @MainActor in try await start() }
        self.task = task
        do {
            return try await task.value
        } catch {
            if self.task == task { self.task = nil }
            throw error
        }
    }
}

/// The resident Claude Code as the bridge's conversation: the guest brought up through
/// `GuestResident` once the userland is on the phone, and the one `GuestSession` from then on.
/// Until the rootfs and Claude Code are both fetched nothing is started and a turn is refused with
/// the userland's own status line, which is what the chat shows.
struct ResidentConversation: GuestConversation {
    let tokens: StoredTokenProvider

    var home: URL { GuestResident.homeDirectory }

    /// The session, started if it was not: refused, as not ready, while the userland is still on
    /// its way or the guest could not start.
    @MainActor
    private func session() async throws -> GuestSession {
        let userland = Userland.shared
        guard userland.isReady else {
            userland.prepare()
            throw GuestBridgeError.notReady(userland.summary)
        }
        do {
            return try await GuestResident.shared.start(tokens: tokens, log: GuestResident.log)
        } catch {
            throw GuestBridgeError.notReady("the guest did not start: \(error)")
        }
    }

    func ready() async throws {
        let session = try await session()
        do {
            try await session.ready()
        } catch GuestSession.Refusal.notResident {
            throw GuestBridgeError.notReady("Claude Code is not resident while the app is in the background")
        } catch {
            throw GuestBridgeError.notReady("Claude Code did not start: \(error)")
        }
    }

    func warm() async {
        guard let session = try? await session() else { return }
        try? await session.ready()
    }

    func use(model: String?) async {
        // A session not started yet starts with the setting (`GuestResident.model`).
        await GuestResident.shared.session?.use(model: model)
    }

    func sessionID() async -> String? {
        if let session = await GuestResident.shared.session { return await session.sessionID }
        return GuestResident.sessionFile.load()
    }

    func residentPID() async -> Int32? {
        await GuestResident.shared.session?.residentPID
    }

    func send(_ text: String, id: String) async throws -> AsyncStream<GuestSession.TurnUpdate> {
        let session = try await session()
        return try await session.send(text, id: id)
    }

    func settle() async {
        await GuestResident.shared.session?.settle()
    }

    func forget() async {
        if let session = await GuestResident.shared.session {
            await session.forgetSession()
        } else {
            GuestResident.sessionFile.clear()
        }
    }

    func status() async -> String {
        let summary = await Userland.shared.summary
        guard let session = await GuestResident.shared.session else { return "\(summary); not started" }
        let phase = await session.currentPhase
        let pid = await session.residentPID.map { ", pid \($0)" } ?? ""
        let model = await session.currentModel ?? "Claude Code's own model"
        return "\(summary); \(phase)\(pid), \(model)"
    }
}

extension GuestResident {
    /// Where the session's and the proxy's lines go: printed in a debug build, where a simulator
    /// run reads them, and nowhere in a release one.
    nonisolated static let log: @Sendable (String) -> Void = { line in
        #if DEBUG
        DebugRun.say("guest: \(line)")
        #endif
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
    static func guestTurn(tokens: StoredTokenProvider, mascot: Mascot,
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
                // Topo on the glass follows the turn: each update moves him, and the turn going,
                // however it went, leaves him idle. Every change of pose is printed.
                mascot.guestTurnBegan()
                var pose = mascot.state.activity
                for await update in updates {
                    mascot.guest(update)
                    if mascot.state.activity != pose {
                        pose = mascot.state.activity
                        say("guest turn \(number) mascot: \(pose.rawValue)")
                    }
                    switch update {
                    case .event(.started(let id, let model)):
                        say("guest turn \(number) model: \(model), session \(id), process \(pid)")
                    case .event(.toolUse(let name, let path)):
                        say("guest turn \(number) tool: \(name)" + (path.map { " \($0)" } ?? ""))
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
                mascot.guestTurnGone()
                if pose != .idle { say("guest turn \(number) mascot: idle") }
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
