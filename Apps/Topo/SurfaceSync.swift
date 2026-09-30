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
/// a delete, for a clear. A save is of the whole slot or nothing: a document or an image that
/// cannot be read just now leaves the save owed for the next try, never a record missing what the
/// file holds and never a record deleted; a save owed for a slot whose document is gone deletes
/// the record, since the record mirrors the file. Each pass makes sure the zone is there first,
/// since a fresh account has none until something writes one. A record belongs to the phone that
/// saved it (`runner`): a sign-out deletes this phone's records and no other's, and one it could
/// not delete is deleted at the next sign-in, before anything else is saved. The primary sweeps
/// the rest — at launch and at each sign-in it deletes every record another runner saved, the
/// leftovers of an earlier primary or of an earlier install of this one — once its own role
/// record, read then, does not say viewer: a takeover writes the old primary's as viewer in the
/// batch that claims the lease, so a demoted phone whose cached role is stale sweeps nothing.
@MainActor
final class SurfaceSync {
    static let shared = SurfaceSync()

    /// Nil where the process cannot reach CloudKit.
    private let records: @MainActor () -> SurfaceRecords?
    private let ensureZone: @Sendable () async throws -> Void
    /// Whether this phone may sweep other runners' records: its role record, read now, is not a
    /// viewer's.
    private let mayOwn: @Sendable () async throws -> Bool
    /// A sweep asked for and not yet done.
    private var sweeping = false
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
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         mayOwn: @escaping @Sendable () async throws -> Bool = {
             try await DeviceRole.read(DeviceIdentity.current, from: TopoCloudKit.database())?.role != .viewer
         },
         store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         runner: String = DeviceIdentity.current.rawValue, defaults: UserDefaults = .standard,
         reloader: SurfaceReloader = .shared, now: @escaping @MainActor () -> Date = { Date() }) {
        self.records = records
        self.ensureZone = ensureZone
        self.mayOwn = mayOwn
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

    /// The slot is about to be written: its record is owed a save before the write, so a process
    /// ended between the write and `changed` still owes it. A save owed for a document the write
    /// never made sends the file as it is, or deletes the record if there is none. Sends nothing
    /// now; `changed` or `cleared` follows the write.
    func expect(slot: String) {
        owe(.save, slot: slot, flushing: false)
    }

    private func owe(_ what: Owed, slot: String, flushing: Bool = true) {
        var owed = owed
        owed[slot] = what
        setOwed(owed)
        // Seen by a pass in flight in this same job, so it settles nothing it read before this
        // write and goes round again; the flush below may run only after that pass's next step.
        if running != nil { again = true }
        if flushing { Task { await flush() } }
    }

    /// This phone is primary and signed in (at launch, at a sign-in, at a takeover): every record
    /// another runner saved is to go, once the role record confirms it.
    func sweep() {
        sweeping = true
        if running != nil { again = true }
        Task { await flush() }
    }

    /// A login ended: nothing it owed is saved, and every `Surface` record this phone saved is to go.
    func forget() {
        setOwed([:])
        defaults.set(true, forKey: Self.forgetKey)
        // A signed-out phone owns nothing, so takes nothing of another's.
        sweeping = false
        if running != nil { again = true }
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
        guard let records = records(), owesForget || sweeping || !owed.isEmpty else { return }
        do {
            try await ensureZone()
        } catch {
            return
        }
        if owesForget {
            do {
                try await records.deleteAll(of: runner)
                defaults.set(false, forKey: Self.forgetKey)
            } catch {
                return
            }
        }
        // Not after a sign-out this pass has not finished, which the guard above returns from.
        if sweeping {
            do {
                if try await mayOwn() { try await records.deleteAll(except: runner) }
                sweeping = false
            } catch {
                // Asked again at the next pass.
            }
        }
        guard let store = store() else { return }
        for (slot, what) in owed.sorted(by: { $0.key < $1.key }) {
            do {
                switch what {
                case .delete:
                    try await records.delete(slot: slot)
                case .save:
                    switch snapshot(slot: slot, store) {
                    case .record(let surface):
                        try await records.save(surface)
                    case .gone:
                        // The record mirrors the file, and the file is gone.
                        try await records.delete(slot: slot)
                    case .unreadable:
                        // Tried again at the next pass, never saved in part and never deleted.
                        continue
                    }
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

    /// A slot's files as a save would send them.
    enum Snapshot {
        /// The document and every image it holds, each read whole.
        case record(SurfaceRecord)
        /// No document file.
        case gone
        /// A document or an image there and not readable now.
        case unreadable
    }

    func snapshot(slot: String, _ store: SurfaceStore) -> Snapshot {
        guard FileManager.default.fileExists(atPath: store.url(slot: slot).path) else { return .gone }
        guard let reading = store.read(slot: slot), reading.readable else { return .unreadable }
        let document = reading.document
        var images: [String: Data] = [:]
        for name in store.imageNames(slot: slot) {
            guard let png = store.imageData(slot: slot, name: name) else { return .unreadable }
            images[name] = png
        }
        return .record(SurfaceRecord(slot: slot, document: document.text, revision: document.revision, updated: now(),
                                     runner: runner, images: images))
    }

    private func setOwed(_ owed: [String: Owed]) {
        if owed.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else { defaults.set(owed.mapValues(\.rawValue), forKey: Self.pendingKey) }
    }
}
