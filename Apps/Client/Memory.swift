#if os(iOS)
import Foundation
import Observation
import TopoAuth
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
/// back after the folder was taken away. Nor can a later cue: the mirror runs only while this
/// device holds a login, the same condition the harness answers under, and a cue arriving without
/// one — a foreground, a launch as a viewer — takes away any folder it finds instead of filling
/// one, so an interrupted sign-out settles at the next cue rather than standing.
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
    private let isSignedIn: @Sendable () -> Bool
    private let ensureZone: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var mirror: VaultMirror?
    private var presenter: VaultPresenter?
    private var zoneReady = false
    private var running: Task<Void, Never>?
    /// A pass a sign-out cancelled, still winding down. Nothing new touches the folder until
    /// it has stopped: a sign-in landing in that moment would otherwise have its first sync
    /// running beside the old one, over the same folder.
    private var stopping: Task<Void, Never>?
    private var queued = false
    /// Advanced by a sign-out and by every pass that begins, so anything left over from before
    /// — a report whose database call has only now returned, a sign-out's folder cleanup that
    /// waited for it — can tell that it is no longer the newest thing to have happened. The
    /// mirror's own cancellation is what stops a stale pass writing to disk; this is what stops
    /// it writing to the screen, and stops one login's cleanup taking away the next one's
    /// folder.
    private var generation = 0

    init(directory: URL, store: MemoryStore, device: DeviceID = DeviceIdentity.current,
         isSignedIn: @escaping @Sendable () -> Bool,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.store = store
        self.device = device
        self.isSignedIn = isSignedIn
        self.ensureZone = ensureZone
        self.now = now
    }

    /// The app's memory: the folder Files shows, over the same CloudKit database the harness
    /// uses and under the same device identity.
    static func standard(tokens: TokenStore = KeychainTokenStore()) -> Memory {
        Memory(directory: Memory.standardDirectory, store: MemoryStore(database: TopoCloudKit.database()),
               isSignedIn: { (try? tokens.load()) != nil })
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
        let asked = generation
        guard isSignedIn() else {
            // A cue can reach a phone with no login — the foreground after a sign-out, a
            // launch as a viewer — and nothing of the memory belongs on one. A folder a
            // sign-out did not get to the end of goes here instead of filling up.
            removeFolder()
            return
        }
        requests += 1
        // Whatever a sign-out cancelled is still stopping; wait it out rather than start a
        // second sync over one folder.
        while let winding = stopping {
            await winding.value
            if stopping == winding { stopping = nil }
        }
        // That wait is as long as the pass it waits for, and a sign-out can happen twice in
        // it: the login checked at the door is not the login this pass would run under, and
        // a sign-out that found no pass to cancel left its cleanup to whatever woke next.
        // So the door is checked again here, after every wait and before anything is made.
        guard isSignedIn() else {
            removeFolder()
            return
        }
        guard generation == asked else {
            // Something moved under this request while it waited. A sign-out's own cleanup
            // owns the folder now; a pass another cue began answers this request too, and
            // asks for one more after it if it is still running.
            if running != nil { queued = true }
            return
        }
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
        // A pass beginning is this device holding a login and using it, which changes hands
        // as much as a sign-out does: a cleanup left over from before this pass takes nothing
        // away, and a report from before it reaches nothing.
        generation += 1
        let mine = generation
        do {
            if !zoneReady {
                try await ensureZone()
                zoneReady = true
            }
            let report = try await vault().sync()
            guard mine == generation else { return }
            lastReport = report
            lastSync = now()
            lastError = nil
        } catch is CancellationError {
            // Sign-out, or the screen going: the mirror stopped before it wrote anything, and
            // there is nothing about that to tell anyone.
        } catch {
            guard mine == generation else { return }
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
        // A sign-out with no pass of its own to stop still has one to wait out when an
        // earlier sign-out's is still stopping: taking that away would leave every request
        // parked behind it free to run as this sign-out's cleanup makes the folder go.
        let winding = running ?? stopping
        stopping = winding
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
        // is one a half-finished pass puts back. And only while this is still the newest thing
        // that happened — a later sign-out has a cleanup of its own, and a pass begun under a
        // new login owns the folder now, so taking it away here would be one login deleting
        // the next one's memory.
        Task { @MainActor [weak self] in
            _ = await winding?.value
            guard let self, self.generation == generation else { return }
            if self.stopping == winding { self.stopping = nil }
            self.removeFolder()
        }
    }

    private func removeFolder() {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
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
/// `PushWake`'s shape, with a different owner. A turn is answered by the screen that is
/// answering, so that handler stands exactly as long as the answering loop does; the memory is
/// mirrored by any phone that holds a login, whatever screen it happens to be showing — a first
/// run, a sign-in that has not been answered yet — so this one follows the login instead.
/// `TopoApp` is where it is put up and taken down, and at a sign-out it is gone, so a push
/// arriving after reaches nothing.
@MainActor
enum MemoryWake {
    static var handler: (@MainActor () async -> Void)?

    static func install(_ handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
    }

    static func remove() {
        handler = nil
    }

    /// Installed exactly while this device holds a login.
    static func follow(signedIn: Bool, memory: Memory) {
        if signedIn {
            install { [memory] in await memory.sync() }
        } else {
            remove()
        }
    }
}
#endif
