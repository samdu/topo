#if os(iOS)
import Foundation
import Observation
import TopoCore

/// The memory as the phone keeps it: a folder of markdown in the app's Documents, mirrored both
/// ways against the store. `<Documents>/Vault` is what Files shows under On My iPhone › Topo, and
/// what an editor opens in place, so the person reads and writes the memory as plain files and a
/// sync is what carries their work to the other devices and brings back what those devices did.
///
/// One mirror for the app and one sync at a time: a request arriving during a pass is served by
/// one more pass after it rather than by a second mirror, since two syncs over one folder would
/// each read what the other was halfway through writing. Every cue is the same call — the
/// foreground, each pass of the answering loop, a reply landing, a silent push saying a revision
/// was written — so how often the folder is current is a question about the cues and not about
/// this.
///
/// Sign-out takes the folder away. The memory is the person's and lives in their iCloud; a phone
/// that is signed out keeps no copy of it. A sync still in flight at that moment is cancelled and
/// writes nothing, and the folder goes once that sync has stopped, so a pass cannot put a file
/// back after the folder was taken away.
@MainActor
@Observable
final class Memory {
    /// The mirrored folder. Fixed, because Files, the person and any editor they use all know it
    /// by where it is.
    let directory: URL

    /// What the last sync did, for the diagnostics screen.
    private(set) var lastReport: VaultMirror.Report?
    /// When a sync last finished without an error.
    private(set) var lastSync: Date?
    /// The last sync to fail, and what it said. A failure is left here and retried on the next
    /// cue; the mirror refuses to act on a partial read, so nothing was half-applied.
    private(set) var lastError: Failure?
    /// How many passes have run, and how many callers have asked for one. A test reads both to
    /// see that requests coalesce: three asks over one pass leave `requests` at three and
    /// `passes` at two.
    private(set) var passes = 0
    private(set) var requests = 0

    struct Failure: Equatable {
        var at: Date
        var message: String
    }

    private let store: MemoryStore
    private let device: DeviceID
    private let ensureZone: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var mirror: VaultMirror?
    private var presenter: VaultPresenter?
    private var zoneReady = false
    private var running: Task<Void, Never>?
    private var queued = false
    /// Bumped by a sign-out, so a pass that was already in flight records nothing when its
    /// database call finally returns. The mirror's own fence is what stops it writing to disk;
    /// this is what stops a stale report and a stale error reaching the screen.
    private var generation = 0

    init(directory: URL, store: MemoryStore, device: DeviceID = DeviceIdentity.current,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.store = store
        self.device = device
        self.ensureZone = ensureZone
        self.now = now
    }

    /// The app's memory: the folder Files shows, over the same CloudKit database the harness
    /// uses and under the same device identity.
    static func standard() -> Memory {
        Memory(directory: Memory.standardDirectory, store: MemoryStore(database: TopoCloudKit.database()))
    }

    static var standardDirectory: URL {
        let documents = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true))
            ?? URL.documentsDirectory
        return documents.appending(path: "Vault", directoryHint: .isDirectory)
    }

    /// Brings the folder and the store into step, and returns once a pass that began no earlier
    /// than this call has finished. One at a time: a call arriving during a pass asks for one
    /// more after it, and however many arrive they ask for the same one.
    func sync() async {
        requests += 1
        if let running {
            queued = true
            await running.value
            return
        }
        let task = Task { @MainActor in await self.drain() }
        running = task
        await task.value
    }

    private func drain() async {
        repeat {
            queued = false
            await onePass()
        } while queued
        running = nil
    }

    private func onePass() async {
        passes += 1
        let generation = self.generation
        do {
            if !zoneReady {
                try await ensureZone()
                zoneReady = true
            }
            let report = try await vault().sync()
            guard generation == self.generation else { return }
            lastReport = report
            lastSync = now()
            lastError = nil
        } catch is CancellationError {
            // Sign-out, or the screen going: the mirror stopped before it wrote anything, and
            // there is nothing about that to tell anyone.
        } catch {
            guard generation == self.generation else { return }
            lastError = Failure(at: now(), message: Self.describe(error))
        }
    }

    /// The mirror, made on the first pass, and the presenter held for as long as it exists. An
    /// open-in-place folder asks its owner to stand as a presenter of it, which is how another
    /// app's coordinated write is announced to this process rather than landing underneath it.
    private func vault() -> VaultMirror {
        if let mirror { return mirror }
        let presenter = VaultPresenter(url: directory)
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        let mirror = VaultMirror(directory: directory, store: store, device: device)
        self.mirror = mirror
        return mirror
    }

    /// Sign-out. The mirror stops, the folder goes, and what the screen was showing about the
    /// memory goes with it.
    func forget() {
        generation += 1
        let generation = self.generation
        let running = self.running
        running?.cancel()
        self.running = nil
        queued = false
        mirror = nil
        zoneReady = false
        lastReport = nil
        lastSync = nil
        lastError = nil
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
        // After the pass in flight has stopped, never during it: a folder taken away mid-write
        // is one a half-finished pass puts back. A sign-in since, which bumps nothing but makes
        // a new mirror, keeps its own folder.
        Task { @MainActor [weak self] in
            _ = await running?.value
            guard let self, self.generation == generation else { return }
            self.removeFolder()
        }
    }

    private func removeFolder() {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: directory, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// What the diagnostics screen shows on the `memory` row.
    var summary: String {
        var parts: [String] = []
        if let lastSync {
            parts.append("synced \(Self.clock(lastSync))")
        } else {
            parts.append(lastError == nil ? "not synced yet" : "never synced")
        }
        if let report = lastReport {
            parts.append("written \(report.written.count), removed \(report.removed.count), "
                + "pushed \(report.pushed.count), deleted \(report.deleted.count), "
                + "skipped \(report.skipped.count)")
        }
        if let lastError {
            parts.append("failed \(Self.clock(lastError.at)): \(lastError.message)")
        }
        return parts.joined(separator: "; ")
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case MemoryError.incompleteVault(let missing, let unreadable):
            let parts = missing.map(\.description).sorted() + unreadable.map(\.name).sorted()
            return "the store is missing revisions (\(parts.joined(separator: ", "))); it syncs again next pass"
        default:
            return "\(error)"
        }
    }
}

/// The app's standing interest in the vault folder, which is what an open-in-place document
/// folder asks of the app that owns it: while this is registered, a coordinated read or write by
/// another app is arbitrated against this process rather than racing it.
///
/// It answers no callbacks. Nothing here watches the folder — a watch on the root would miss a
/// save inside a subfolder anyway, and the foreground and the answering loop are what say when
/// to look.
final class VaultPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    init(url: URL) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
    }
}

/// Who a silent push about a revision wakes.
///
/// The same shape as `PushWake`, and for the same reason: the screen that is syncing installs a
/// handler while it stands and takes it away when it goes, so a push arriving after a sign-out
/// reaches nothing.
@MainActor
enum MemoryWake {
    static var handler: (@MainActor () async -> Void)?

    static func install(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    static func remove() {
        handler = nil
    }
}
#endif
