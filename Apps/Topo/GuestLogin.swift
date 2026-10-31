import Foundation
import TopoAuth
import TopoTools
import TopoUserland

/// Claude Code's login, in the guest's own unmodified `claude`. `claude auth login --claudeai`
/// runs with no resident beside it (`GuestSession.withoutResident`), since the two are `claude`
/// processes over one credentials file, `~/.claude/.credentials.json` in the guest's home, which
/// is the app's `Documents/home`. Its `BROWSER` is `topo-browser`, which hands the loopback URL to
/// the sign-in's sheet through `topo open-url`; the paste-page URL it prints is kept for the
/// fallback, and a pasted `code#state` is written to its stdin. Topo holds no Claude.ai token.
struct GuestLogin: ClaudeLogin {
    /// How long `auth status` and `auth logout` may take.
    static let bound: Duration = .seconds(20)

    /// Waits for the rootfs and Claude Code to be on the phone, saying what the downloads are at,
    /// then brings the guest up.
    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
        while !(await Userland.shared.isReady) {
            await Userland.shared.prepare()
            progress(await Userland.shared.summary)
            try await Task.sleep(for: .seconds(1))
        }
        progress("starting")
        _ = try await GuestResident.shared.start(log: GuestResident.log)
    }

    func begin(_ heard: @escaping @Sendable (LoginEvent) -> Void) async throws -> any LoginAttempt {
        let session = try await GuestResident.shared.start(log: GuestResident.log)
        let environment = try await Self.environment(browser: true)
        return try await withCheckedThrowingContinuation { (started: CheckedContinuation<any LoginAttempt, Error>) in
            Task {
                await session.withoutResident {
                    await Self.run(environment: environment, heard: heard, started: started)
                }
            }
        }
    }

    /// Runs the login to its end; `started` hears the attempt once the process is up, or why it
    /// is not.
    private static func run(environment: [String: String], heard: @escaping @Sendable (LoginEvent) -> Void,
                            started: CheckedContinuation<any LoginAttempt, Error>) async {
        let process: GuestProcess
        do {
            process = try await Guest.shared.spawn("/bin/sh", command(["auth", "login", "--claudeai"]), environment: environment)
        } catch {
            started.resume(throwing: error)
            return
        }
        let attempt = GuestLoginAttempt(process: process)
        let browser = await LoginBrowser.shared.open { url in heard(.browser(url)) }
        started.resume(returning: attempt)
        var said: [String] = []
        for await line in process.lines {
            if let page = pastePage(in: line) { heard(.pastePage(page)) }
            said.append(line)
        }
        let status = await exited(process)
        await LoginBrowser.shared.close(browser)
        await attempt.finish()
        GuestResident.log("login: claude auth login exited \(status.map(String.init) ?? "unknown")")
        heard(.ended(end(status: status, ended: attempt.ended, said: said + process.errors.split(separator: "\n").map(String.init))))
    }

    /// What a login's end says: exit 0 is the credential written; exit 1 its `Login failed: …`
    /// line, or the last thing it said; anything else, or a login the app ended, is stopped.
    static func end(status: Int32?, ended: Bool, said: [String]) -> LoginEnd {
        guard !ended else { return .stopped }
        switch status {
        case 0: return .succeeded
        case 1:
            let lines = said.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .failed(lines.last { $0.hasPrefix("Login failed") } ?? lines.last ?? "Claude Code's sign-in failed.")
        default: return .stopped
        }
    }

    /// The paste-page URL in a line the login printed: its `redirect_uri` is Claude's hosted code
    /// page, where the loopback one is `localhost`.
    static func pastePage(in line: String) -> URL? {
        guard let start = line.range(of: "https://") else { return nil }
        let text = line[start.lowerBound...].prefix { !$0.isWhitespace }
        guard let url = URL(string: String(text)), OpenURLTool.accepts(url),
              let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "redirect_uri" })?.value,
              URL(string: redirect)?.host == "platform.claude.com" else { return nil }
        return url
    }

    /// The process's status once it has been reaped; its pipes close first, so this waits a
    /// little for the wait to land, and answers nil when it never does.
    private static func exited(_ process: GuestProcess) async -> Int32? {
        for _ in 0..<100 {
            if process.hasExited { return process.exitStatus }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process.exitStatus
    }

    func status() async throws -> ClaudeLoginStatus {
        let environment = try await Self.environment(browser: false)
        let run: @Sendable () async -> Result<Guest.Exit, Error> = {
            await Result { try await Guest.shared.run("/bin/sh", Self.command(["auth", "status", "--json"]),
                                                       environment: environment, within: Self.bound) }
        }
        let exit: Guest.Exit
        if let session = await GuestResident.shared.session {
            exit = try await session.withoutResident(run).get()
        } else {
            exit = try await run().get()
        }
        guard let status = ClaudeLoginStatus.parse(exit.output) else {
            throw GuestBridgeError.notReady("claude auth status said nothing readable (exit \(exit.status))")
        }
        return status
    }

    /// `claude auth logout` with no resident beside it, when the guest is up in this process; then
    /// the credentials file is removed from the host side whether or not that ran, so a phone whose
    /// guest never came up is signed out all the same.
    func logout() async -> Bool {
        if let session = await GuestResident.shared.session, let environment = try? await Self.environment(browser: false) {
            _ = await session.withoutResident {
                let exit = try? await Guest.shared.run("/bin/sh", Self.command(["auth", "logout"]),
                                                       environment: environment, within: Self.bound)
                GuestResident.log("login: claude auth logout exited \(exit.map { String($0.status) } ?? "unrun")")
            }
        }
        return Self.removeCredentials()
    }

    func discardCredential() {
        Self.removeCredentials()
    }

    /// Claude Code's credential in the guest's home, as the host sees it.
    nonisolated static var credentialsFile: URL {
        GuestResident.homeDirectory.appendingPathComponent(".claude/.credentials.json")
    }

    /// True when the file is gone, which a removal that threw because there was none also is.
    @discardableResult
    static func removeCredentials() -> Bool {
        do {
            try FileManager.default.removeItem(at: credentialsFile)
        } catch {
            if FileManager.default.fileExists(atPath: credentialsFile.path) {
                GuestResident.log("login: the credentials file would not go: \(error)")
            }
        }
        return !FileManager.default.fileExists(atPath: credentialsFile.path)
    }

    /// `claude <arguments>`, from the home, as the resident is started.
    static func command(_ arguments: [String]) -> [String] {
        ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", ClaudeCodeInstaller.command] + arguments
    }

    /// The login's environment: the guest's, the tool service's (for `topo open-url`), the home,
    /// and `BROWSER` for the login itself. No `ANTHROPIC_BASE_URL`: the login's exchange is
    /// Claude Code's own, to Claude's hosts.
    @MainActor
    static func environment(browser: Bool) async throws -> [String: String] {
        var environment = Guest.environment
        environment.merge(try await GuestResident.shared.prepareTools(log: GuestResident.log)) { _, new in new }
        environment.merge(GuestResident.developerEnvironment) { _, new in new }
        environment["HOME"] = ClaudeLauncher.home
        environment["BROWSER"] = browser ? ClaudeLauncher.home + "/" + GuestTools.browserPath : nil
        return environment
    }
}

/// One running `claude auth login`.
final class GuestLoginAttempt: LoginAttempt, @unchecked Sendable {
    let process: GuestProcess
    private let lock = NSLock()
    private var endedByApp = false
    private var finished = false
    private var ending: Task<Void, Never>?

    init(process: GuestProcess) {
        self.process = process
    }

    var ended: Bool { lock.withLock { endedByApp } }

    func paste(_ code: String) async throws {
        try await process.write(code)
    }

    /// Ends the login. With no resident beside it the guest's every task is the login's, so this
    /// does nothing once the login has finished: past that the resident may be starting again.
    func end() async {
        let task: Task<Void, Never>? = lock.withLock {
            guard !finished else { return nil }
            endedByApp = true
            if ending == nil {
                ending = Task { [process] in
                    let termination = await process.terminate(within: .seconds(5))
                    GuestResident.log("login: ended by the app, \(termination)")
                }
            }
            return ending
        }
        await task?.value
    }

    /// The login has exited: an end already under way is waited for, and none starts after.
    func finish() async {
        let task = lock.withLock {
            finished = true
            return ending
        }
        await task?.value
    }
}
