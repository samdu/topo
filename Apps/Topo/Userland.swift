import Foundation
import Observation
import TopoAuth
import TopoProxy
import TopoUserland

/// A file of the manifest as the downloader hands it over: where it landed, verified, and the pin
/// the userland checks it against again before anything reads it.
struct Fetched: Sendable, Equatable {
    let file: URL
    let size: Int64
    let sha256: String
    /// The release the entry is pinned to, where it names one (Claude Code's version).
    let version: String?
}

/// Where one of the guest's downloads comes from: fetched and verified by the downloader.
@MainActor
protocol DownloadSource: AnyObject {
    /// Whether the file is already on disk and verified, so a fetch has nothing to do.
    var isFetched: Bool { get }
    /// The downloader's own line while a fetch is on its way.
    var status: String { get }
    /// Starts a fetch, or carries on the one under way, and settles `done` once: with the file
    /// and its pin, or with why the fetch failed.
    func fetch(_ done: @escaping @MainActor (Result<Fetched, Error>) -> Void)
}

/// One single-file entry of the model manifest, fetched by `ModelDownloads`: the rootfs tarball,
/// or Claude Code.
@MainActor
final class DownloadedEntry: DownloadSource {
    private let id: String
    private let downloads: ModelDownloads

    init(_ id: String, downloads: ModelDownloads = .shared) {
        self.id = id
        self.downloads = downloads
    }

    var isFetched: Bool { downloads.status(for: id) == .present }

    var status: String {
        if case .failed(let why) = downloads.status(for: id) { return "download failed: \(why)" }
        return downloads.describe([id])
    }

    func fetch(_ done: @escaping @MainActor (Result<Fetched, Error>) -> Void) {
        downloads.start([id])
        downloads.whenSettled([id]) { [downloads, id] result in
            done(result.mapError { $0 as Error }.flatMap {
                guard let model = downloads.manifest?.model(id), let file = model.files.first else {
                    return .failure(ModelStoreError.unknownModel(id))
                }
                return .success(Fetched(file: downloads.store.location(of: file, in: model), size: file.size,
                                        sha256: file.sha256, version: model.version))
            })
        }
    }
}

/// The guest on this phone, as two downloads. Its root: Alpine's minirootfs, fetched by
/// `ModelDownloads` as one more pinned entry of the manifest and verified there, then made into a
/// fakefs by the fork's own importer (`RootfsInstaller`) under Application Support; once the
/// fakefs is whole nothing is fetched or imported again. And Claude Code: Anthropic's binary,
/// another pinned entry, which stays in its manifest home and is handed out as the installer that
/// verifies and mounts it into a booted guest (`ClaudeCodeInstaller`), so nothing here copies it.
/// Both are asked for on every foreground, like the ear's and the voice's models. A fetch that
/// fails ends in `failed` with its reason, and the next `prepare` fetches afresh. `bootGuest` boots
/// the guest once per process: the resident Claude Code's start calls it (`GuestResident`, which
/// the chat's harness and `DebugRun.guestTurn` bring up), and so does the debug guest command
/// (`DebugRun.userland`); the tests boot their own.
@MainActor
@Observable
final class Userland {
    static let shared = Userland()

    enum Phase: Equatable {
        /// The tarball is not yet on disk and verified; the downloader's own status says where it
        /// stands.
        case fetching
        case importing
        case ready(RootfsInstaller.Outcome)
        case failed(String)
    }

    /// Where Claude Code stands: on its way, on the phone and verified by the downloader at its
    /// pin, or failed.
    enum ClaudePhase: Equatable {
        case fetching
        case fetched(ClaudeCodePin)
        case failed(String)
    }

    private(set) var phase: Phase = .fetching
    private(set) var claude: ClaudePhase = .fetching
    /// Whether this launch had to fetch the tarball: a fakefs imported from a file an earlier
    /// launch downloaded is not one this launch fetched.
    private(set) var fetchedThisLaunch = false
    /// Whether this launch had to fetch Claude Code, rather than finding it on the phone.
    private(set) var claudeFetchedThisLaunch = false
    let installer: RootfsInstaller
    private let source: any DownloadSource
    private let claudeSource: any DownloadSource
    /// Whether a fetch is on its way, so a foreground during one asks for nothing more.
    private var fetching = false
    private var claudeFetching = false
    private var readiness: [CheckedContinuation<URL, Error>] = []
    private var claudeReadiness: [CheckedContinuation<ClaudeCodeInstaller, Error>] = []
    private var claudeInstaller: ClaudeCodeInstaller?
    private var booting: Task<ClaudeCodeInstaller.Installed, Error>?

    init(installer: RootfsInstaller = .standard(), source: (any DownloadSource)? = nil,
         claudeSource: (any DownloadSource)? = nil) {
        self.installer = installer
        self.source = source ?? DownloadedEntry(ModelManifest.rootfs)
        self.claudeSource = claudeSource ?? DownloadedEntry(ModelManifest.claudeCode)
    }

    /// Asks for both downloads: the rootfs, imported once it is here, and Claude Code. Idempotent,
    /// and called on every foreground so that a download or an import that failed is tried again.
    func prepare() {
        prepareRootfs()
        prepareClaude()
    }

    /// A fakefs already whole asks for nothing — not even the tarball, which a later launch does
    /// not need.
    private func prepareRootfs() {
        switch phase {
        case .importing, .ready: return
        case .fetching, .failed: break
        }
        if installer.isReady {
            finish(.success(.reused))
            return
        }
        guard !fetching else { return }
        fetching = true
        if !source.isFetched { fetchedThisLaunch = true }
        phase = .fetching
        source.fetch { [weak self] result in
            guard let self else { return }
            self.fetching = false
            switch result {
            case .success(let fetched): self.install(fetched.file, RootfsPin(size: fetched.size, sha256: fetched.sha256))
            case .failure(let error): self.finish(.failure(error))
            }
        }
    }

    /// Claude Code on the phone asks for nothing more this process; its digest is checked again by
    /// the installer at every mount, not here.
    private func prepareClaude() {
        if case .fetched = claude { return }
        guard !claudeFetching else { return }
        claudeFetching = true
        if !claudeSource.isFetched { claudeFetchedThisLaunch = true }
        claude = .fetching
        claudeSource.fetch { [weak self] result in
            guard let self else { return }
            self.claudeFetching = false
            let waiting = self.claudeReadiness
            self.claudeReadiness = []
            switch result {
            case .success(let fetched) where (fetched.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                // A pin without its version — absent, empty or blank — is not one `claude --version`
                // can be held to.
                let why = "the manifest's \(ModelManifest.claudeCode) entry names no version"
                self.claude = .failed(why)
                waiting.forEach { $0.resume(throwing: ModelDownloadFailure(id: ModelManifest.claudeCode, why: why)) }
            case .success(let fetched):
                let pin = ClaudeCodePin(version: fetched.version ?? "", size: fetched.size, sha256: fetched.sha256)
                let installer = ClaudeCodeInstaller(binary: fetched.file, pin: pin)
                self.claudeInstaller = installer
                self.claude = .fetched(pin)
                waiting.forEach { $0.resume(returning: installer) }
            case .failure(let error):
                self.claude = .failed(String(describing: error))
                waiting.forEach { $0.resume(throwing: error) }
            }
        }
    }

    /// The installer for Claude Code once the downloader has it: now if it does, otherwise after
    /// `prepare` has fetched it. Throws what the fetch failed with. Installing it into a booted
    /// guest is the caller's, off the main thread, since the digest reads the whole binary.
    func claudeCode() async throws -> ClaudeCodeInstaller {
        if let claudeInstaller { return claudeInstaller }
        return try await withCheckedThrowingContinuation { continuation in
            claudeReadiness.append(continuation)
            prepareClaude()
        }
    }

    /// The guest booted with Claude Code mounted, once per process: waits for both downloads,
    /// boots the kernel on the fakefs, and verifies and mounts Claude Code off the main thread
    /// (the digest reads the whole binary). Every caller after the first gets the first's
    /// answer, failure included, since the kernel boots at most once.
    func bootGuest() async throws -> ClaudeCodeInstaller.Installed {
        if let booting { return try await booting.value }
        let task = Task { @MainActor in
            let fakefs = try await self.ready()
            let claude = try await self.claudeCode()
            try Guest.shared.boot(fakefs: fakefs)
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try claude.install(into: Guest.shared) })
                }
            }
        }
        booting = task
        return try await task.value
    }

    private func install(_ tarball: URL, _ pin: RootfsPin) {
        phase = .importing
        let installer = installer
        // The digest reads four megabytes and the import writes a few thousand files: blocking
        // work, so a queue of its own rather than the cooperative pool.
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try installer.install(from: tarball, pin: pin) }
            Task { @MainActor in self.finish(result) }
        }
    }

    private func finish(_ result: Result<RootfsInstaller.Outcome, Error>) {
        switch result {
        case .success(let outcome):
            phase = .ready(outcome)
            let waiting = readiness
            readiness = []
            waiting.forEach { $0.resume(returning: installer.fakefs) }
        case .failure(let error):
            phase = .failed(String(describing: error))
            let waiting = readiness
            readiness = []
            waiting.forEach { $0.resume(throwing: error) }
        }
    }

    /// The fakefs once it is whole: now if it is, otherwise after `prepare` has fetched and
    /// imported it. Throws what the fetch or the import failed with.
    func ready() async throws -> URL {
        if case .ready = phase { return installer.fakefs }
        return try await withCheckedThrowingContinuation { continuation in
            readiness.append(continuation)
            prepare()
        }
    }

    /// Whether both downloads are on the phone: the fakefs whole and Claude Code fetched at its
    /// pin. Until they are, the phone does not answer.
    var isReady: Bool {
        guard case .ready = phase, case .fetched = claude else { return false }
        return true
    }

    /// The diagnostics screen's `userland` row, one clause per download, so it says which of the
    /// two a guest is waiting on: the rootfs waiting, downloading, verifying, importing or ready,
    /// and Claude Code waiting, downloading, verifying or downloaded at its version.
    var summary: String {
        let rootfs: String
        switch phase {
        case .fetching: rootfs = source.status
        case .importing: rootfs = "importing"
        case .ready: rootfs = "ready"
        case .failed(let why): rootfs = "failed: \(why)"
        }
        let claudeCode: String
        switch claude {
        case .fetching: claudeCode = claudeSource.status
        case .fetched(let pin): claudeCode = "\(pin.version) downloaded"
        case .failed(let why): claudeCode = "failed: \(why)"
        }
        return "rootfs \(rootfs); claude code \(claudeCode)"
    }
}

#if DEBUG
extension DebugRun {
    static let userlandVariable = "TOPO_DEBUG_USERLAND"

    /// What the guest's authorization was granted, for the device run: the scope string and the
    /// days left on the long-lived token (never a value), or that none is held and the guest runs
    /// on the ordinary access token.
    static func mintLine(_ guest: Tokens?, now: Date = Date()) -> String {
        guard let guest else { return "userland: mint: none held, the guest runs on the ordinary access token" }
        let scope = guest.scopes.isEmpty ? "(none returned)" : guest.scopes.joined(separator: " ")
        let days = Int((guest.expiresAt.timeIntervalSince(now) / 86_400).rounded())
        return "userland: mint scope: \(scope), expires in \(days) days"
    }

    /// Whether the ordinary tokens are still refreshable after sign-in, for the device run: one
    /// refresh with the refresh token they hold, asking for their own scopes, and the scope string
    /// it granted (never a value) or why it was refused. The refreshed tokens are written back, so
    /// a refresh token the server rotates is not lost.
    static func ordinaryRefreshLine(_ ordinary: Tokens?, provider: StoredTokenProvider) async -> String {
        await ordinaryRefresh(ordinary, provider: provider).line
    }

    /// The refresh behind `ordinaryRefreshLine`, with its refusal when it was refused.
    private static func ordinaryRefresh(_ ordinary: Tokens?, provider: StoredTokenProvider) async -> (line: String, refusal: (any Error)?) {
        guard let ordinary else { return ("userland: ordinary refresh: not checked, not signed in", nil) }
        guard !ordinary.refreshToken.isEmpty else {
            return ("userland: ordinary refresh: not checked, no refresh token held (a seeded setup token)", nil)
        }
        do {
            let refreshed = try await provider.refresh()
            return ("userland: ordinary refresh scope: \(refreshed.scopes.isEmpty ? "(none returned)" : refreshed.scopes.joined(separator: " "))", nil)
        } catch {
            return ("userland: ordinary refresh failed: \(error)", error)
        }
    }

    /// A fallback that answers with the refusal the launch's own refresh already met, so the
    /// guest's hand-over does not spend a second grant on the same refresh token.
    private struct Refused: TokenProvider {
        let error: any Error
        func accessToken() async throws -> String { throw error }
    }

    /// The guest's token and the launch's three lines about it, with one refresh grant at most:
    /// the ordinary tokens are refreshed once for the diagnostic line first, so the fallback
    /// hands over the access token that refresh wrote back rather than refreshing again, and a
    /// refused refresh is the fallback's answer too. The lines are printed in the order the device
    /// run reads them: the hand-over, the guest's token, the ordinary refresh. `provider` is the
    /// app's one provider over the ordinary tokens, the chat's too, so a refresh the chat has in
    /// flight is the one this joins.
    static func handOver(port: UInt16, guestStore: TokenStore,
                         provider: StoredTokenProvider) async -> (environment: [String: String], lines: [String]) {
        let refresh = await ordinaryRefresh(try? provider.store.load(), provider: provider)
        let fallback: TokenProvider = refresh.refusal.map { Refused(error: $0) } ?? provider
        let credential = GuestCredential(store: guestStore, fallback: fallback)
        do {
            let handed = try await APIProxy.guestEnvironment(port: port, credential: credential)
            return (handed.environment, [
                "userland: proxy on \(APIProxy.baseURL(port: port)), guest token: \(handed.source == .longLived ? "long-lived" : "access token")",
                mintLine(try? guestStore.load()),
                refresh.line,
            ])
        } catch {
            return ([:], ["userland: proxy on \(APIProxy.baseURL(port: port)), no guest token: \(error)", refresh.line])
        }
    }

    /// `TOPO_DEBUG_USERLAND=<command>`: on launch, fetch or reuse the rootfs and Claude Code, boot
    /// the guest, verify Claude Code and mount it at `/usr/local/bin/claude`, start the API proxy on
    /// loopback, run the command under `/bin/sh -c` in `Guest.environment` (the environment every
    /// launch path hands the guest, Claude Code's updater off in it) with `ANTHROPIC_BASE_URL`
    /// pointing at the proxy and `CLAUDE_CODE_OAUTH_TOKEN` set to the guest's token, and print what
    /// it wrote and how it exited, each line prefixed, for `scripts/simulator-run.sh --userland` to
    /// assert on. The proxy's own lines are printed as `proxy:`. With no login the command still
    /// runs, with the base URL and no token. The only path in the app that boots the guest.
    /// Nothing at all when the variable is absent. `tokens` is the app's one provider over the
    /// ordinary tokens.
    @MainActor
    static func userland(_ userland: Userland = .shared, tokens: StoredTokenProvider,
                         environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let command = environment[userlandVariable], !command.isEmpty else { return }
        say("userland: \(userland.summary)")
        do {
            _ = try await userland.ready()
            switch userland.phase {
            case .ready(.reused): say("userland: rootfs reused: nothing fetched, nothing imported")
            case .ready(.imported):
                say("userland: rootfs \(userland.fetchedThisLaunch ? "fetched and imported" : "imported from an earlier download")")
            default: break
            }
            let claude = try await userland.claudeCode()
            let version = claude.pin.version
            say("userland: claude code \(version) "
                + (userland.claudeFetchedThisLaunch ? "fetched" : "reused: nothing fetched, nothing copied"))
            let installed = try await userland.bootGuest()
            say("userland: booted")
            let milliseconds = Int(installed.verification / .milliseconds(1))
            say("userland: claude code \(installed.version) verified in \(milliseconds) ms, mounted at \(installed.command)")
            let proxy = try APIProxy(log: { line in say("proxy: \(line)") })
            let port = try await proxy.start()
            defer { Task { await proxy.stop() } }
            var guestEnvironment = Guest.environment
            guestEnvironment["ANTHROPIC_BASE_URL"] = APIProxy.baseURL(port: port)
            let handed = await handOver(port: port, guestStore: KeychainTokenStore.guest, provider: tokens)
            guestEnvironment.merge(handed.environment) { _, new in new }
            handed.lines.forEach(say)
            let exit = try await Guest.shared.run("/bin/sh", ["-c", command], environment: guestEnvironment)
            var lines = exit.output.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last == "" { lines.removeLast() }
            for line in lines {
                say("guest: \(line)")
            }
            for line in exit.errors.split(separator: "\n") {
                say("guest stderr: \(line)")
            }
            say("guest exit: \(exit.status)")
        } catch {
            say("userland error: \(error)")
        }
        say("userland done")
    }
}
#endif
