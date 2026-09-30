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
/// reports as behind. A sign-out deletes every `Surface` record in the zone; one it could not
/// delete is deleted at the next sign-in, before anything else is saved.
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
    var pending: Set<String> { Set(defaults.stringArray(forKey: Self.pendingKey) ?? []) }

    /// Whether a sign-out's deletes are still owed.
    var owesForget: Bool { defaults.bool(forKey: Self.forgetKey) }

    /// The slot's file changed — set, an image, cleared — so its record is owed. Answers at
    /// once; the record follows.
    func changed(slot: String) {
        setPending(pending.union([slot]))
        Task { await flush() }
    }

    /// A login ended: nothing it owed is saved, and every `Surface` record is to go.
    func forget() {
        setPending([])
        defaults.set(true, forKey: Self.forgetKey)
        Task { await flush() }
    }

    /// Sends what is owed: a sign-out's deletes first, then each pending slot as its file is now
    /// — saved when it has a document, deleted when it has none. A slot stays pending until the
    /// store confirms it; a failure leaves it for the next try.
    /// One pass at a time: a flush asked for while one runs makes it go round again, and waits
    /// for it.
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
            } while again
        }
        running = task
        await task.value
        running = nil
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
        for slot in pending.sorted() {
            do {
                if let surface = surface(slot: slot, store) {
                    try await records.save(surface)
                } else {
                    try await records.delete(slot: slot)
                }
                // A write made while this one was on its way is owed again, and `changed`
                // asked for another pass to send it.
                if !again { setPending(pending.subtracting([slot])) }
            } catch {
                continue
            }
        }
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

    private func setPending(_ slots: Set<String>) {
        if slots.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else { defaults.set(slots.sorted(), forKey: Self.pendingKey) }
    }
}
