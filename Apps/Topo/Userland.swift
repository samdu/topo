import Foundation
import Observation
import TopoUserland

/// The guest's root on this phone: Alpine's minirootfs, fetched by `ModelDownloads` as one more
/// pinned entry of the manifest and verified there, then made into a fakefs by the fork's own
/// importer (`RootfsInstaller`) under Application Support. Asked for on every foreground, like the
/// ear's and the voice's models; once the fakefs is whole nothing is fetched or imported again.
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
    private var readiness: [CheckedContinuation<URL, Error>] = []

    init(installer: RootfsInstaller = .standard()) {
        self.installer = installer
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
        let downloads = ModelDownloads.shared
        if downloads.status(for: ModelManifest.rootfs) != .present { fetchedThisLaunch = true }
        phase = .fetching
        downloads.start([ModelManifest.rootfs])
        downloads.whenPresent([ModelManifest.rootfs]) { [weak self] in
            guard let self, self.phase == .fetching else { return }
            self.install()
        }
    }

    private func install() {
        guard let manifest = ModelDownloads.shared.manifest,
              let model = manifest.model(ModelManifest.rootfs), let file = model.files.first else {
            finish(.failure(ModelStoreError.unknownModel(ModelManifest.rootfs)))
            return
        }
        phase = .importing
        let tarball = ModelDownloads.shared.store.location(of: file, in: model)
        let pin = RootfsPin(size: file.size, sha256: file.sha256)
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
        case .fetching:
            if case .failed(let why) = ModelDownloads.shared.status(for: ModelManifest.rootfs) {
                return "download failed: \(why)"
            }
            return ModelDownloads.shared.describe([ModelManifest.rootfs])
        case .importing: return "importing the rootfs"
        case .ready: return "ready"
        case .failed(let why): return "failed: \(why)"
        }
    }
}

#if DEBUG
extension DebugRun {
    static let userlandVariable = "TOPO_DEBUG_USERLAND"

    /// `TOPO_DEBUG_USERLAND=<command>`: on launch, fetch or reuse the rootfs, boot the guest, run
    /// the command under `/bin/sh -c`, and print what it wrote and how it exited, each line
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
            try Guest.shared.boot(fakefs: fakefs)
            say("userland: booted")
            let exit = try await Guest.shared.run("/bin/sh", ["-c", command])
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
