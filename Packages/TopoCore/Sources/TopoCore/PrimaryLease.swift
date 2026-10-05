import Foundation

/// The one mutable record: who is primary right now.
///
/// `epoch` goes up by one on every claim, so a lease can be told from an
/// earlier one held by the same device. `endpoint` is where the holder
/// answers probes; its form is the probe's business.
public struct Lease: Hashable, Sendable {
    public static let recordType = "PrimaryLease"
    public static let recordID = RecordID("primary")

    public let holder: DeviceID
    public let endpoint: String?
    public let epoch: Int64
    public let expiresAt: Date

    public init(holder: DeviceID, endpoint: String?, epoch: Int64, expiresAt: Date) {
        self.holder = holder
        self.endpoint = endpoint
        self.epoch = epoch
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { expiresAt <= now }

    public init?(record: Record) {
        guard record.type == Lease.recordType,
              let holder = record.string("holder"),
              let epoch = record.int("epoch"),
              let expiresAt = record.date("expiresAt") else { return nil }
        self.init(holder: DeviceID(holder), endpoint: record.string("endpoint"), epoch: epoch, expiresAt: expiresAt)
    }

    /// The record for this lease, carrying `changeTag` so the save is a
    /// compare-and-set against the version that was read.
    func record(changeTag: String?) -> Record {
        var fields: [String: FieldValue] = [
            "holder": .string(holder.rawValue),
            "epoch": .int(epoch),
            "expiresAt": .date(expiresAt),
        ]
        if let endpoint { fields["endpoint"] = .string(endpoint) }
        return Record(type: Lease.recordType, id: Lease.recordID, fields: fields, changeTag: changeTag)
    }
}

/// Asks the holder of a lease whether it still holds it.
///
/// The implementation owns the transport and the timeout. It returns true
/// only when the holder is reached and confirms this lease, epoch included:
/// a device that answers on the endpoint but no longer counts itself primary
/// (it restarted, or `isPrimary()` is false) answers no, so the asker claims
/// instead of deferring to a listener with nothing behind it. No answer is
/// false.
public protocol LeaseProbe: Sendable {
    func confirms(_ lease: Lease) async -> Bool
}

public struct LeaseTiming: Hashable, Sendable {
    /// How long a claim or heartbeat is good for.
    public var duration: TimeInterval
    /// How often a holder heartbeats. Half the duration, so one missed
    /// heartbeat does not lose the lease.
    public var heartbeat: TimeInterval

    public init(duration: TimeInterval = 10, heartbeat: TimeInterval = 5) {
        self.duration = duration
        self.heartbeat = heartbeat
    }

    public static let standard = LeaseTiming()
}

public enum LeaseOutcome: Hashable, Sendable {
    /// This device holds the lease and is heartbeating it.
    case primary(Lease)
    /// Another device holds it and confirmed so when probed.
    case held(by: Lease)
    /// Another device took the lease from this one and is still heartbeating
    /// it, but does not answer probes: the two can both reach CloudKit and
    /// not each other. This device is not primary and does not claim; it
    /// runs the turn itself, or through the log, until that lease lapses,
    /// which is one duration after its holder's last heartbeat.
    case unreachable(Lease)
    /// The record kept changing under us. Try again next turn.
    case contended
}

/// Claims and keeps the primary lease for one device.
///
/// Handover is probe-driven. `acquire()` is the turn-time path: it reads
/// the lease, and if another device holds it, probes that device and claims
/// only on no answer, so a dead holder costs one probe timeout. An expired
/// lease is claimed without a probe. Every write is a compare-and-set on
/// the record's tag, so of two claimants one wins and the other re-reads,
/// probes the winner and defers.
///
/// A holder heartbeats every `timing.heartbeat` on its own, from the moment
/// it becomes primary until it loses the lease. It learns it has been
/// displaced the moment a heartbeat or an `acquire()` finds the record
/// changed under it: it stops counting itself primary at once and yields to
/// the lease that displaced it, so two devices that cannot reach each other
/// settle on one primary instead of taking the lease from each other every
/// turn. A holder that cannot reach CloudKit at all stops counting itself
/// primary when its lease expires (`isPrimary()`), judged on a monotonic
/// clock as well as the wall clock so a clock correction on wake cannot
/// revive it. So two brains last at most one heartbeat interval after a
/// claim over a live holder, and one duration after a claim over a
/// cut-off or suspended one.
///
/// A holder whose heartbeats ran late has lost nothing to anyone: its lease
/// lapsed with the record still its own. A batch it saves then
/// (`heartbeat(saving:)`) claims afresh in that same batch, over the record
/// as the server holds it, and only while that record is still the lease
/// this device let lapse.
///
/// A device that yielded to a lease waits for that lease to lapse before
/// claiming, one duration, because the probe is exactly what it cannot
/// trust; any device that has not yielded takes over a dead holder on one
/// probe. The hub alone takes over a live holder, through `takeOver()`,
/// because a hub is primary whenever it is awake. There is no release. A
/// holder that goes away is found by the next probe.
public actor PrimaryLease {
    private let database: any RecordDatabase
    private let device: DeviceID
    private let endpoint: String?
    private let probe: any LeaseProbe
    private let timing: LeaseTiming
    private let now: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The lease record this device last successfully wrote, if any.
    private var heldRecord: Record?
    /// When the held lease lapses on the monotonic clock: set with every
    /// write, so a wall clock stepped backwards cannot revive a lease.
    private var heldUntil: TimeInterval = 0
    /// The lease this device held when it lapsed locally, its heartbeats
    /// late, with no other device known to have claimed: what a batch may
    /// claim afresh over (`heartbeat(saving:)`). Nil once this device holds
    /// a lease again, has yielded, or has abandoned its claim.
    private var lapsedRecord: Record?
    /// The lease that took ours, while it stays fresh.
    private var yieldedTo: Lease?
    private var heartbeatTask: Task<Void, Never>?
    /// Counts `abandon()` calls, so a batch that was waiting on a read or a save across one
    /// knows the claim it belonged to is gone.
    private var abandonments = 0

    /// - Parameters:
    ///   - now: the wall clock the record's expiry is written and read in;
    ///     tests move it by hand.
    ///   - monotonic: seconds on a clock that only goes forward, keeps
    ///     counting through sleep and ignores clock adjustments; the local
    ///     expiry is judged on it too. The default is `mach_continuous_time`.
    ///   - sleep: how the heartbeat loop waits; tests drive it.
    public init(database: any RecordDatabase, device: DeviceID, endpoint: String?,
                probe: any LeaseProbe, timing: LeaseTiming = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = PrimaryLease.continuousUptime,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.database = database
        self.device = device
        self.endpoint = endpoint
        self.probe = probe
        self.timing = timing
        self.now = now
        self.monotonic = monotonic
        self.sleep = sleep
    }

    /// Seconds on `mach_continuous_time`: monotonic, counting through
    /// sleep, unmoved by adjustments to the system time.
    public static let continuousUptime: @Sendable () -> TimeInterval = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = TimeInterval(mach_continuous_time()) * TimeInterval(info.numer) / TimeInterval(info.denom)
        return nanos / 1_000_000_000
    }

    /// The lease this device holds, or nil.
    public var held: Lease? { heldRecord.flatMap(Lease.init(record:)) }

    /// True while this device holds an unexpired lease. Needs no network:
    /// a holder that has not managed a heartbeat inside the duration is not
    /// primary, whatever the server says. Expiry is judged on the wall
    /// clock and the monotonic clock, whichever lapses first, so a wall
    /// clock corrected backwards on wake does not revive a stale lease.
    public func isPrimary() -> Bool {
        guard let lease = held else { return false }
        return !hasLapsed(lease)
    }

    private func hasLapsed(_ lease: Lease) -> Bool {
        lease.isExpired(at: now()) || monotonic() >= heldUntil
    }

    /// The turn-time path. Returns `.primary` when this device holds the
    /// lease afterwards, whether by keeping, retaking or claiming it.
    public func acquire() async throws -> LeaseOutcome {
        for _ in 0..<3 {
            let current = try await database.fetch(Lease.recordID)

            guard let record = current else {
                if let lease = try await write(holder(epoch: 1), over: nil) { return .primary(lease) }
                continue
            }

            guard let lease = Lease(record: record) else {
                // A record that exists but does not parse blocks everyone
                // until someone claims over it. Nobody can be holding it.
                let epoch = (record.int("epoch") ?? 0) + 1
                if let mine = try await write(holder(epoch: epoch), over: record.changeTag) { return .primary(mine) }
                continue
            }

            if let mine = heldRecord {
                if mine.changeTag == record.changeTag {
                    if !lease.isExpired(at: now()) {
                        if let renewed = try await write(holder(epoch: lease.epoch), over: record.changeTag) {
                            return .primary(renewed)
                        }
                        continue
                    }
                    // Our own lease, lapsed without anyone taking it: a fresh claim.
                } else {
                    displaced(by: lease)
                }
            }

            if lease.isExpired(at: now()) {
                if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag) { return .primary(mine) }
                continue
            }

            if await probe.confirms(lease) {
                heldRecord = nil
                lapsedRecord = nil
                return .held(by: lease)
            }

            if hasYielded(to: lease) {
                return .unreachable(lease)
            }

            if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag) { return .primary(mine) }
        }
        heldRecord = nil
        return .contended
    }

    /// The hub's path: takes the lease from whoever holds it, live or not,
    /// without a probe. A hub is primary for as long as it is awake, so a
    /// phone holding the lease when the hub launches or wakes is displaced,
    /// learns so at its next heartbeat or turn, and yields. Nothing but the
    /// hub calls this; every other device goes through `acquire()`.
    public func takeOver() async throws -> LeaseOutcome {
        for _ in 0..<3 {
            let current = try await database.fetch(Lease.recordID)
            guard let record = current else {
                if let lease = try await write(holder(epoch: 1), over: nil) { return .primary(lease) }
                continue
            }
            guard let lease = Lease(record: record) else {
                let epoch = (record.int("epoch") ?? 0) + 1
                if let mine = try await write(holder(epoch: epoch), over: record.changeTag) { return .primary(mine) }
                continue
            }
            if let mine = heldRecord, mine.changeTag == record.changeTag, !lease.isExpired(at: now()) {
                if let renewed = try await write(holder(epoch: lease.epoch), over: record.changeTag) {
                    return .primary(renewed)
                }
                continue
            }
            if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag) { return .primary(mine) }
        }
        heldRecord = nil
        return .contended
    }

    /// Claims over exactly the lapsed lease `record` the caller read: a compare-and-set on that
    /// version, so a heartbeat landing between the read and the claim is a conflict and the
    /// claim fails, rather than a claim over a holder that turned out to be alive. True when
    /// this device holds the lease afterwards. False, with nothing written, when the record is
    /// not a lapsed lease of another device or the version moved.
    public func claim(overLapsed record: Record) async throws -> Bool {
        guard let lease = Lease(record: record), lease.holder != device, lease.isExpired(at: now()) else { return false }
        return try await write(holder(epoch: lease.epoch + 1), over: record.changeTag) != nil
    }

    /// Stops counting this device primary and stops its heartbeats, without touching the
    /// record, which lapses on its own within one duration. For a claim whose owner cannot
    /// keep it (a takeover whose role records failed to land): the alternative is a lease
    /// renewed forever by nobody, which answers no turns and blocks every other device.
    public func abandon() {
        abandonments += 1
        heldRecord = nil
        lapsedRecord = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Creates the lease record for this device only if none exists: the
    /// atomic first claim, which exactly one of any number of devices
    /// launching together wins. True for the winner. The record is not held
    /// or heartbeated here; it lapses in one duration, and `acquire()` takes
    /// it properly when the first turn runs. False when a record exists,
    /// whoever holds it and however old.
    public func claimIfNone() async throws -> Bool {
        do {
            _ = try await database.save(holder(epoch: 1).record(changeTag: nil))
            return true
        } catch RecordDatabaseError.serverRecordChanged {
            return false
        }
    }

    /// Extends the held lease by one duration. Returns false, the lease no
    /// longer held, when the server holds a different version (another
    /// device has claimed it) or the lease has already expired locally (this
    /// device missed its heartbeats and is not primary until it claims again).
    /// True is this device primary as the call returns: an answer that comes
    /// back after the lease it renewed has run out is false.
    public func heartbeat() async throws -> Bool {
        guard let record = heldRecord, let lease = Lease(record: record) else { return false }
        if hasLapsed(lease) {
            lapse()
            return false
        }
        guard try await write(holder(epoch: lease.epoch), over: record.changeTag) != nil else { return false }
        return isPrimary()
    }

    /// Saves `records` and a heartbeat of the held lease in one atomic batch,
    /// so the records land only if no other device has claimed the lease
    /// since this one last wrote it: a turn appended this way is never the
    /// work of a displaced brain. Returns the saved records, or nil with nothing
    /// applied when the lease is not held: never granted, or taken by
    /// another device (which this device then yields to, as after a failed
    /// heartbeat). A conflict on any record but the lease propagates as the
    /// database threw it, again with nothing applied.
    ///
    /// A lease that lapsed locally, its heartbeats late, is not yet anyone
    /// else's. The record is read, and while it is still that lease (this
    /// device, the epoch it held) the batch carries a fresh claim over the
    /// version read, one epoch on, in place of the heartbeat: what a slow
    /// network cost is the lease's freshness, not the work done under it. A
    /// claim by another device since, before the read or between it and the
    /// save, refuses the batch as it refuses a heartbeat.
    public func heartbeat(saving records: [Record]) async throws -> [Record]? {
        // Every read and save here is a wait other calls run during, so what each answer finds
        // is judged again: an abandonment ends the batch, and a lease claimed meanwhile is
        // never replaced by an answer about an older one.
        let began = abandonments
        for _ in 0..<3 {
            let over: Record, claim: Lease, heartbeatOf: Lease?
            if let record = heldRecord, let lease = Lease(record: record), !hasLapsed(lease) {
                (over, claim, heartbeatOf) = (record, holder(epoch: lease.epoch), lease)
            } else {
                if heldRecord != nil { lapse() }
                guard lapsedRecord != nil else { return nil }
                let server = try await database.fetch(Lease.recordID)
                // Abandoned while the read was out: the batch was that claim's, and a lease
                // taken since is not its to write under.
                guard abandonments == began else { return nil }
                // Held again while the read was out: the batch goes as a heartbeat of that.
                if heldRecord != nil { continue }
                // Judged after the read, not before it: a yield while the read was out leaves
                // nothing to claim over.
                guard let lapsed = lapsedRecord.flatMap(Lease.init(record:)) else { return nil }
                guard let server, let current = Lease(record: server),
                      current.holder == device, current.epoch == lapsed.epoch, current.endpoint == endpoint else {
                    lapsedRecord = nil
                    if let taker = server.flatMap(Lease.init(record:)), taker.holder != device { yieldedTo = taker }
                    return nil
                }
                (over, claim, heartbeatOf) = (server, holder(epoch: current.epoch + 1), nil)
            }
            let deadline = monotonic() + timing.duration
            do {
                let saved = try await database.save(records + [claim.record(changeTag: over.changeTag)])
                // The records are in the log whatever happened here meanwhile. The lease this
                // save wrote is taken as held unless the claim was abandoned while the save was
                // out, or a later claim of this device's is held by now.
                let superseded = held.map { $0.epoch > claim.epoch } ?? false
                if abandonments == began, !superseded {
                    let tag = saved.first(where: { $0.id == Lease.recordID })?.changeTag
                    heldRecord = claim.record(changeTag: tag)
                    heldUntil = deadline
                    lapsedRecord = nil
                    yieldedTo = nil
                    startHeartbeats()
                }
                return saved.filter { $0.id != Lease.recordID }
            } catch RecordDatabaseError.serverRecordChanged(let id, let server) where id == Lease.recordID {
                guard abandonments == began else { return nil }
                let winner = Lease(record: server)
                if let winner, let mine = held, winner.holder == device, winner.epoch == mine.epoch,
                   winner.endpoint == endpoint {
                    // The server's record is the lease this device holds: an overlapping
                    // heartbeat of ours got there first, or a claim made while the save was out.
                    // The batch goes again over it. A heartbeat's version is taken as the one
                    // held; a later claim's is already known.
                    if mine.epoch == heartbeatOf?.epoch { heldRecord = server }
                    continue
                }
                // A fresh claim that lost to a late heartbeat of this device's own, landing
                // between the read and the save, reads again.
                if heartbeatOf == nil, heldRecord == nil, lapsedRecord != nil, winner?.holder == device { continue }
                heldRecord = nil
                lapsedRecord = nil
                yieldedTo = winner
                return nil
            } catch RecordDatabaseError.unknownItem(let id) where id == Lease.recordID {
                guard abandonments == began else { return nil }
                heldRecord = nil
                lapsedRecord = nil
                return nil
            }
        }
        return nil
    }

    /// The held lease has lapsed locally. It is kept as the one a batch may
    /// claim afresh over, since nobody is known to have taken it.
    private func lapse() {
        lapsedRecord = heldRecord
        heldRecord = nil
    }

    private func holder(epoch: Int64) -> Lease {
        Lease(holder: device, endpoint: endpoint, epoch: epoch, expiresAt: now() + timing.duration)
    }

    private func displaced(by lease: Lease) {
        heldRecord = nil
        lapsedRecord = nil
        yieldedTo = lease
    }

    /// Same holder and epoch; the expiry moves with every heartbeat.
    private func hasYielded(to lease: Lease) -> Bool {
        guard let y = yieldedTo else { return false }
        return y.holder == lease.holder && y.epoch == lease.epoch
    }

    /// Compare-and-set of the lease record. On success this device holds the
    /// saved version, its local deadline is set, and its heartbeats are
    /// running. On a conflict the lease is forgotten and the lease that
    /// won, written just now by a device that is evidently alive, is the
    /// one this device yields to; unless this device holds the lease and
    /// the winner is that same lease, written by an overlapping heartbeat
    /// of ours, which is a success. Anything but a conflict propagates.
    private func write(_ lease: Lease, over changeTag: String?) async throws -> Lease? {
        do {
            let deadline = monotonic() + timing.duration
            let saved = try await database.save(lease.record(changeTag: changeTag))
            // A late heartbeat's answer arriving after a batch claimed afresh over it: the
            // lease held is the later one, and this answer is about a version it replaced.
            if let newer = held, newer.epoch > lease.epoch { return newer }
            heldRecord = lease.record(changeTag: saved.changeTag)
            heldUntil = deadline
            lapsedRecord = nil
            yieldedTo = nil
            startHeartbeats()
            return lease
        } catch RecordDatabaseError.serverRecordChanged(_, let server) {
            let winner = Lease(record: server)
            if heldRecord != nil, let winner, winner.holder == lease.holder, winner.epoch == lease.epoch,
               winner.endpoint == lease.endpoint {
                // A concurrent heartbeat of ours got there first: the lease
                // is still this one, at the server's version. Only a holder
                // can say so; two cold instances creating the same lease
                // look identical to each other and one must lose.
                heldRecord = server
                return winner
            }
            if let winner, let newer = held, winner.holder == device, winner.epoch == newer.epoch,
               winner.epoch > lease.epoch, winner.endpoint == endpoint {
                // A late heartbeat that lost to this device's own fresh claim, made by a
                // batch while the heartbeat was out: the lease held is that claim.
                return newer
            }
            heldRecord = nil
            lapsedRecord = nil
            yieldedTo = winner
            return nil
        } catch RecordDatabaseError.unknownItem {
            if heldRecord?.changeTag == changeTag { heldRecord = nil }
            return nil
        }
    }

    private func startHeartbeats() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { await runHeartbeats() }
    }

    private func runHeartbeats() async {
        defer { heartbeatTask = nil }
        while heldRecord != nil, !Task.isCancelled {
            do { try await sleep(timing.heartbeat) } catch { return }
            guard heldRecord != nil else { return }
            // A transport failure is not a lost lease; the local expiry decides.
            _ = try? await heartbeat()
        }
    }
}
