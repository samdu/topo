import Foundation
import TopoCore

/// The phone's side of a slot's `Surface` record (TopoCore's `SurfaceRecords`), which is how the
/// watch, with no app group in common with the phone, gets the mind's widgets.
///
/// Every write `topo widget` makes to a slot is followed by a save of the slot's record, and a
/// clear by a delete; the file is written first and the record after, so the phone's own widgets
/// never wait on iCloud. What has not reached the record yet is kept in the defaults — outside
/// `Surfaces/`, which a sign-out empties — and tried again on the next write and whenever the
/// phone is signed in (at launch, after signing in): a slot waiting there is one `topo widget`
/// reports as behind. Each waiting slot remembers what it owes: a save, for a set or an image, or
/// a delete, for a clear — only a clear ever deletes a record, so a document that cannot be read
/// just now is left for the next try rather than taken for a slot cleared. A sign-out deletes
/// every `Surface` record in the zone; one it could not delete is deleted at the next sign-in,
/// before anything else is saved.
@MainActor
final class SurfaceSync {
    static let shared = SurfaceSync()

    /// Nil where the process cannot reach CloudKit.
    private let records: @MainActor () -> SurfaceRecords?
    private let store: @MainActor () -> SurfaceStore?
    private let runner: String
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date

    static let pendingKey = "topo.surfaces.pending"
    static let forgetKey = "topo.surfaces.forget"

    private var running: Task<Void, Never>?
    private var again = false
    /// Run at the end of each pass, before the loop decides whether to go round again: the suite's
    /// way into the moment a write can land between the last pass and the loop's end.
    var afterPass: (@MainActor () -> Void)?

    /// What a waiting slot owes its record.
    enum Owed: String {
        case save, delete
    }

    init(records: @escaping @MainActor () -> SurfaceRecords? = { SurfaceRecords(database: TopoCloudKit.database()) },
         store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         runner: String = DeviceIdentity.current.rawValue, defaults: UserDefaults = .standard,
         reloader: SurfaceReloader = .shared, now: @escaping @MainActor () -> Date = { Date() }) {
        self.records = records
        self.store = store
        self.runner = runner
        self.defaults = defaults
        self.now = now
        reloader.onForget { [weak self] in self?.forget() }
    }

    /// The slots whose record is behind their file: a save or a delete not yet confirmed.
    var pending: Set<String> { Set(owed.keys) }

    /// Each waiting slot and what it owes.
    var owed: [String: Owed] {
        (defaults.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]).compactMapValues(Owed.init(rawValue:))
    }

    /// Whether a sign-out's deletes are still owed.
    var owesForget: Bool { defaults.bool(forKey: Self.forgetKey) }

    /// The slot was set or given an image, so its record is owed a save. Answers at once; the
    /// record follows.
    func changed(slot: String) {
        owe(.save, slot: slot)
    }

    /// The slot was cleared, so its record is owed a delete.
    func cleared(slot: String) {
        owe(.delete, slot: slot)
    }

    private func owe(_ what: Owed, slot: String) {
        var owed = owed
        owed[slot] = what
        setOwed(owed)
        Task { await flush() }
    }

    /// A login ended: nothing it owed is saved, and every `Surface` record is to go.
    func forget() {
        setOwed([:])
        defaults.set(true, forKey: Self.forgetKey)
        Task { await flush() }
    }

    /// Sends what is owed: a sign-out's deletes first, then each waiting slot — a save of its
    /// document as its file is now, or the delete a clear asked for. A slot stays waiting until
    /// the store confirms it; a failure, or a document that cannot be read just now, leaves it for
    /// the next try.
    /// One pass at a time: a flush asked for while one runs makes it go round again, and waits
    /// for it. The loop lets go of `running` in the same turn as its last look at `again`, so a
    /// flush asked for after that look starts a pass of its own rather than waiting on one that
    /// has already ended.
    func flush() async {
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                again = false
                await pass()
                afterPass?()
            } while again
            running = nil
        }
        running = task
        await task.value
    }

    private func pass() async {
        guard let records = records() else { return }
        if owesForget {
            do {
                try await records.deleteAll()
                defaults.set(false, forKey: Self.forgetKey)
            } catch {
                return
            }
        }
        guard let store = store() else { return }
        for (slot, what) in owed.sorted(by: { $0.key < $1.key }) {
            do {
                switch what {
                case .delete:
                    try await records.delete(slot: slot)
                case .save:
                    guard let surface = surface(slot: slot, store) else {
                        // No file at all: the slot went by some path that owes nothing (a
                        // sign-out clears what is owed), and there is nothing to save. A file
                        // that is there but cannot be read now is tried again, never deleted.
                        if !FileManager.default.fileExists(atPath: store.url(slot: slot).path) { settle(slot, what) }
                        continue
                    }
                    try await records.save(surface)
                }
                settle(slot, what)
            } catch {
                continue
            }
        }
    }

    /// Takes `slot` off the waiting list, unless something owed it anew while this was on its way.
    private func settle(_ slot: String, _ what: Owed) {
        guard !again, owed[slot] == what else { return }
        var owed = owed
        owed[slot] = nil
        setOwed(owed)
    }

    /// The slot's record as its file is now, or nil when it has no document.
    func surface(slot: String, _ store: SurfaceStore) -> SurfaceRecord? {
        guard let reading = store.read(slot: slot), reading.readable else { return nil }
        let document = reading.document
        var images: [String: Data] = [:]
        for name in store.imageNames(slot: slot) { images[name] = store.imageData(slot: slot, name: name) }
        return SurfaceRecord(slot: slot, document: document.text, revision: document.revision, updated: now(),
                             runner: runner, images: images)
    }

    private func setOwed(_ owed: [String: Owed]) {
        if owed.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else { defaults.set(owed.mapValues(\.rawValue), forKey: Self.pendingKey) }
    }
}
