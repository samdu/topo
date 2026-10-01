import Foundation
import TopoCore

/// The phone's side of a slot's `Surface` record (TopoCore's `SurfaceRecords`), which is how the
/// watch, with no app group in common with the phone, gets the mind's widgets.
///
/// Every write `topo widget` makes to a slot is followed by a save of the slot's record, and a
/// clear by a clear of it; the file is written first and the record after, so the phone's own
/// widgets never wait on iCloud. What has not reached the record yet is kept in the defaults —
/// outside `Surfaces/`, which a sign-out empties — and tried again on the next write and whenever
/// the phone is signed in (at launch, after signing in): a slot waiting there is one `topo widget`
/// reports as behind. Each waiting slot remembers what it owes: a save, for a set or an image, or
/// a clear. A save is of the whole slot or nothing: a document or an image that cannot be read
/// just now leaves the save owed, never a record missing what the file holds and never a record
/// cleared; a save owed for a slot whose document is gone clears the record, which mirrors the
/// file. Each pass makes sure the zone is there first, since a fresh account has none until
/// something writes one.
///
/// A record belongs to the phone that saved it (`runner`), and more than one phone can be writing
/// at once while a takeover lands, so no write here trusts a check made before the read it acts
/// on. Every write is one compare-and-set on the change tag of a read taken for it, and the role
/// is read after that read: a takeover saves the old primary's role record as viewer with its
/// first heartbeat, before the new primary is primary and writes any slot, so a read that saw the
/// new primary's record is followed by a role read that sees the demotion. A write refused because
/// the record moved is read again and judged again, and a phone whose role record says viewer
/// drops what it owed, save for a record of its own still on the slot, which it clears under that
/// record's tag. A save this phone made whose role flipped between its check and the save is
/// undone by a clear under that save's own tag, dropped if the new primary has written since.
/// Nothing is ever physically deleted: a clear is a tombstone (`SurfaceRecords.clear`), since
/// CloudKit's deletes carry no tag to check.
///
/// A sign-out clears this phone's own records and no other's; one it could not clear is cleared at
/// the next sign-in, before anything else is saved. The primary sweeps the rest — at launch, at
/// each sign-in and at a takeover it clears every record another runner saved, the leftovers of an
/// earlier primary or of an earlier install of this one; a save found there since its read is
/// cleared only when its runner's role record says viewer.
@MainActor
final class SurfaceSync {
    static let shared = SurfaceSync()

    /// Nil where the process cannot reach CloudKit.
    private let records: @MainActor () -> SurfaceRecords?
    private let ensureZone: @Sendable () async throws -> Void
    /// Whether this phone may sweep other runners' records: its role record, read now, is not a
    /// viewer's.
    private let mayOwn: @Sendable () async throws -> Bool
    /// Whether the phone a runner names has a viewer's role record, read now.
    private let demoted: @Sendable (String) async throws -> Bool
    /// A sweep asked for and not yet done.
    private var sweeping = false
    /// Counts sweeps asked for, so a sweep that was running when another was asked does not
    /// answer for it.
    private var sweepsAsked = 0
    /// Counts the logins ended here. A pass reads it at its start and before each write, so that
    /// nothing it read before a sign-out is acted on after it: a signed-out phone owns nothing.
    private var signOuts = 0
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

    /// Whether `device` may write records another phone saved: its role record, read now, is not
    /// a viewer's. A device with no role record may; a takeover writes one for each device it
    /// finds primary (`RoleSelector.primariesToDemote`).
    nonisolated static func roleAllows(device: DeviceID, database: any RecordDatabase) async throws -> Bool {
        try await DeviceRole.read(device, from: database)?.role != .viewer
    }

    init(records: @escaping @MainActor () -> SurfaceRecords? = { SurfaceRecords(database: TopoCloudKit.database()) },
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         roles: @escaping @Sendable () -> any RecordDatabase = { TopoCloudKit.database() },
         mayOwn: (@Sendable () async throws -> Bool)? = nil,
         demoted: (@Sendable (String) async throws -> Bool)? = nil,
         store: @escaping @MainActor () -> SurfaceStore? = { SurfaceStore.shared() },
         runner: String = DeviceIdentity.current.rawValue, defaults: UserDefaults = .standard,
         reloader: SurfaceReloader = .shared, now: @escaping @MainActor () -> Date = { Date() }) {
        self.records = records
        self.ensureZone = ensureZone
        // The role records are read from `roles` unless a test answers for them: this phone's own
        // under its runner, and another phone's under the runner its record names.
        self.mayOwn = mayOwn ?? { try await SurfaceSync.roleAllows(device: DeviceID(runner), database: roles()) }
        self.demoted = demoted ?? { try await !SurfaceSync.roleAllows(device: DeviceID($0), database: roles()) }
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
        sweepsAsked += 1
        if running != nil { again = true }
        Task { await flush() }
    }

    /// A login ended: nothing it owed is saved, and every `Surface` record this phone saved is to go.
    func forget() {
        setOwed([:])
        defaults.set(true, forKey: Self.forgetKey)
        // A signed-out phone owns nothing, so takes nothing of another's, a sweep in flight included.
        sweeping = false
        signOuts += 1
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
        let login = signOuts
        do {
            try await ensureZone()
        } catch {
            return
        }
        if owesForget {
            do {
                try await forgetOwn(records)
                // A sign-out landing while this one ran owes its own pass.
                guard signOuts == login else { return }
                defaults.set(false, forKey: Self.forgetKey)
            } catch {
                return
            }
        }
        // Not after a sign-out this pass has not finished, which the guard above returns from.
        if sweeping {
            let asked = sweepsAsked
            do {
                try await sweepOthers(records, login: login)
                if sweepsAsked == asked, signOuts == login { sweeping = false }
            } catch {
                // Asked again at the next pass.
            }
        }
        guard let store = store() else { return }
        for (slot, what) in owed.sorted(by: { $0.key < $1.key }) {
            let target: SurfaceRecord?
            switch what {
            case .delete:
                target = nil
            case .save:
                switch snapshot(slot: slot, store) {
                case .record(let surface): target = surface
                // The record mirrors the file, and the file is gone.
                case .gone: target = nil
                // Tried again at the next pass, never saved in part and never cleared.
                case .unreadable: continue
                }
            }
            guard signOuts == login else { return }
            do {
                if try await write(target, slot: slot, records, login: login) { settle(slot, what) }
            } catch {
                continue
            }
        }
    }

    /// The slot's record made `target` (cleared when nil), one compare-and-set at a time. Answers
    /// whether the slot owes nothing more: written, kept as a newer save of this phone's, or
    /// dropped because this phone may no longer write it.
    private func write(_ target: SurfaceRecord?, slot: String, _ records: SurfaceRecords, login: Int) async throws -> Bool {
        for _ in 0..<3 {
            let current = try await records.read(slot: slot)
            // Whether this phone may write at all, asked after the read it acts on. A demoted
            // phone owes nothing but the slot back: a save of its own still on it (one whose undo
            // never ran) is cleared under its tag, and anything else is left.
            guard try await mayOwn() else {
                guard current.holds, current.runner == runner else { return true }
                do {
                    try await records.clear(slot: slot, runner: runner, at: now(), over: current)
                    return true
                } catch RecordDatabaseError.serverRecordChanged {
                    continue
                }
            }
            // What the ended login owed is owed no more.
            guard signOuts == login else { return true }
            do {
                guard let target else {
                    try await records.clear(slot: slot, runner: runner, at: now(), over: current)
                    return true
                }
                guard try await records.save(target, over: current) == .saved else { return true }
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
            // Saved. A takeover that landed between the role read and the save leaves this
            // phone's write over a slot the new primary has not written: undone under the
            // save's own tag, and left alone if the new primary has written since.
            if try await !mayOwn() {
                let mine = try await records.read(slot: slot)
                if mine.holds, mine.runner == runner {
                    do {
                        try await records.clear(slot: slot, runner: runner, at: now(), over: mine)
                    } catch RecordDatabaseError.serverRecordChanged {}
                }
            }
            return true
        }
        return false
    }

    /// A sign-out: each record this phone saved and that still holds a slot is cleared under the
    /// tag it was read with; one another phone has written since is that phone's, and left.
    private func forgetOwn(_ records: SurfaceRecords) async throws {
        for read in try await records.all() where read.holds && read.runner == runner {
            guard let slot = read.slot else { continue }
            do {
                try await records.clear(slot: slot, runner: runner, at: now(), over: read)
            } catch RecordDatabaseError.serverRecordChanged {}
        }
    }

    /// The primary's sweep: every record another runner saved that still holds a slot is cleared
    /// under the tag it was read with, once the role, read after them, allows it. A clear refused
    /// because the record moved is read again: another runner's save there is cleared in turn
    /// only when that runner's role record says viewer (a demoted phone's save, landing as the
    /// sweep read), so a phone that still reads itself primary never clears a save made since
    /// by one that is not demoted either; this phone's own is left.
    /// Every clear is made only while the login the sweep began in stands: one a sign-out lands
    /// before is never sent.
    private func sweepOthers(_ records: SurfaceRecords, login: Int) async throws {
        let others = try await records.all().filter { $0.holds && $0.runner != runner }
        guard !others.isEmpty, try await mayOwn() else { return }
        for first in others {
            guard let slot = first.slot else { continue }
            var read = first
            for _ in 0..<3 {
                guard signOuts == login else { return }
                do {
                    try await records.clear(slot: slot, runner: runner, at: now(), over: read)
                    break
                } catch RecordDatabaseError.serverRecordChanged {
                    read = try await records.read(slot: slot)
                    guard read.holds, let other = read.runner, other != runner, try await mayOwn(),
                          try await demoted(other) else { break }
                }
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
