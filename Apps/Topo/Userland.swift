import Foundation
import Observation
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
/// fails ends in `failed` with its reason, and the next `prepare` fetches afresh. Nothing boots
/// the guest here: only a debug launch does (`DebugRun.userland`), and the tests.
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
            case .success(let fetched) where (fetched.version ?? "").trimmingCharacters(in: .whitespaces).isEmpty:
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

    /// `TOPO_DEBUG_USERLAND=<command>`: on launch, fetch or reuse the rootfs and Claude Code, boot
    /// the guest, verify Claude Code and mount it at `/usr/local/bin/claude`, run the command under
    /// `/bin/sh -c` in `Guest.environment` (the environment every launch path hands the guest,
    /// Claude Code's updater off in it), and print what it wrote and how it exited, each line
    /// prefixed, for `scripts/simulator-run.sh --userland` to assert on. The only path in the app
    /// that boots the guest. Nothing at all when the variable is absent.
    @MainActor
    static func userland(_ userland: Userland = .shared,
                         environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let command = environment[userlandVariable], !command.isEmpty else { return }
        say("userland: \(userland.summary)")
        do {
            let fakefs = try await userland.ready()
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
            try Guest.shared.boot(fakefs: fakefs)
            say("userland: booted")
            let installed = try await withCheckedThrowingContinuation { continuation in
                // The digest reads the whole binary: a queue of its own, not the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try claude.install(into: Guest.shared) })
                }
            }
            let milliseconds = Int(installed.verification / .milliseconds(1))
            say("userland: claude code \(installed.version) verified in \(milliseconds) ms, mounted at \(installed.command)")
            let exit = try await Guest.shared.run("/bin/sh", ["-c", command], environment: Guest.environment)
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
