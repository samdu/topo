import Foundation
import Observation
import TopoAuth
import TopoProxy
import TopoUserland

/// Where the rootfs tarball comes from: fetched, verified by the downloader, and handed over with
/// the pin the installer checks it against again.
@MainActor
protocol RootfsSource: AnyObject {
    /// Whether the tarball is already on disk and verified, so a fetch has nothing to do.
    var isFetched: Bool { get }
    /// The downloader's own line while a fetch is on its way.
    var status: String { get }
    /// Starts a fetch, or carries on the one under way, and settles `done` once: with the
    /// tarball and its pin, or with why the fetch failed.
    func fetch(_ done: @escaping @MainActor (Result<(tarball: URL, pin: RootfsPin), Error>) -> Void)
}

/// The rootfs as one more entry of the model manifest, fetched by `ModelDownloads`.
@MainActor
final class DownloadedRootfs: RootfsSource {
    private let downloads: ModelDownloads

    init(downloads: ModelDownloads = .shared) {
        self.downloads = downloads
    }

    var isFetched: Bool { downloads.status(for: ModelManifest.rootfs) == .present }

    var status: String {
        if case .failed(let why) = downloads.status(for: ModelManifest.rootfs) { return "download failed: \(why)" }
        return downloads.describe([ModelManifest.rootfs])
    }

    func fetch(_ done: @escaping @MainActor (Result<(tarball: URL, pin: RootfsPin), Error>) -> Void) {
        downloads.start([ModelManifest.rootfs])
        downloads.whenSettled([ModelManifest.rootfs]) { [downloads] result in
            done(result.mapError { $0 as Error }.flatMap {
                guard let model = downloads.manifest?.model(ModelManifest.rootfs), let file = model.files.first else {
                    return .failure(ModelStoreError.unknownModel(ModelManifest.rootfs))
                }
                return .success((downloads.store.location(of: file, in: model), RootfsPin(size: file.size, sha256: file.sha256)))
            })
        }
    }
}

/// The guest's root on this phone: Alpine's minirootfs, fetched by `ModelDownloads` as one more
/// pinned entry of the manifest and verified there, then made into a fakefs by the fork's own
/// importer (`RootfsInstaller`) under Application Support. Asked for on every foreground, like the
/// ear's and the voice's models; once the fakefs is whole nothing is fetched or imported again.
/// A fetch that fails ends in `failed` with its reason, and the next `prepare` fetches afresh.
/// Nothing boots the guest here: only a debug launch does (`DebugRun.userland`), and the tests.
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

    private(set) var phase: Phase = .fetching
    /// Whether this launch had to fetch the tarball: a fakefs imported from a file an earlier
    /// launch downloaded is not one this launch fetched.
    private(set) var fetchedThisLaunch = false
    let installer: RootfsInstaller
    private let source: any RootfsSource
    /// Whether a fetch is on its way, so a foreground during one asks for nothing more.
    private var fetching = false
    private var readiness: [CheckedContinuation<URL, Error>] = []

    init(installer: RootfsInstaller = .standard(), source: (any RootfsSource)? = nil) {
        self.installer = installer
        self.source = source ?? DownloadedRootfs()
    }

    /// Asks for the rootfs and imports it once it is here. Idempotent, and called on every
    /// foreground so that a download or an import that failed is tried again. A fakefs already
    /// whole asks for nothing — not even the tarball, which a later launch does not need.
    func prepare() {
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
            case .success(let fetched): self.install(fetched.tarball, fetched.pin)
            case .failure(let error): self.finish(.failure(error))
            }
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

    /// The diagnostics screen's `userland` row: waiting, downloading, verifying, importing, ready.
    var summary: String {
        switch phase {
        case .fetching: return source.status
        case .importing: return "importing the rootfs"
        case .ready: return "ready"
        case .failed(let why): return "failed: \(why)"
        }
    }
}

#if DEBUG
extension DebugRun {
    static let userlandVariable = "TOPO_DEBUG_USERLAND"

    /// `TOPO_DEBUG_USERLAND=<command>`: on launch, fetch or reuse the rootfs, boot the guest, start
    /// the API proxy on loopback, run the command under `/bin/sh -c` with `ANTHROPIC_BASE_URL`
    /// pointing at the proxy and `CLAUDE_CODE_OAUTH_TOKEN` set to the guest's token, and print what
    /// it wrote and how it exited, each line prefixed, for `scripts/simulator-run.sh --userland` to
    /// assert on. The proxy's own lines are printed as `proxy:`. With no login the command still
    /// runs, with the base URL and no token. The only path in the app that boots the guest.
    /// Nothing at all when the variable is absent.
    @MainActor
    static func userland(_ userland: Userland = .shared,
                         credential: GuestCredential = GuestCredential(store: KeychainTokenStore.guest,
                                                                       fallback: StoredTokenProvider(store: KeychainTokenStore())),
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
            try Guest.shared.boot(fakefs: fakefs)
            say("userland: booted")
            let proxy = try APIProxy(log: { line in say("proxy: \(line)") })
            let port = try await proxy.start()
            defer { Task { await proxy.stop() } }
            var guestEnvironment = Guest.environment
            guestEnvironment["ANTHROPIC_BASE_URL"] = APIProxy.baseURL(port: port)
            do {
                let handed = try await APIProxy.guestEnvironment(port: port, credential: credential)
                guestEnvironment.merge(handed.environment) { _, new in new }
                say("userland: proxy on \(APIProxy.baseURL(port: port)), guest token: \(handed.source == .longLived ? "long-lived" : "access token")")
            } catch {
                say("userland: proxy on \(APIProxy.baseURL(port: port)), no guest token: \(error)")
            }
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
