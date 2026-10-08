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
    /// How often a holder heartbeats. Half the duration.
    public var heartbeat: TimeInterval

    public init(duration: TimeInterval = 10, heartbeat: TimeInterval = 5) {
        self.duration = duration
        self.heartbeat = heartbeat
    }

    /// How long one read or write of the lease may go unanswered before it
    /// is given up as failed. The lease's calls go one at a time, so a
    /// request that stalls holds the next heartbeat up, and this bounds each
    /// request, not the call that makes it: a pass is a read and a write, twice
    /// this, and a call whose write loses to another writer goes again, three
    /// passes at most. A heartbeat due a full
    /// interval after the last, behind one request that used all of it, goes
    /// out with a second left of the duration; behind more than that, or
    /// when its own answer takes longer than this, the lease lapses locally
    /// and is claimed afresh by the next turn or batch.
    public var patience: TimeInterval { max(duration - heartbeat - 1, 1) }

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
    /// The record kept changing under us, or the lease was abandoned
    /// (`abandon()`) after this call was made. Nothing is held. Try again
    /// next turn.
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
///
/// One operation at a time. Every call that reads or writes the record for
/// this device (`acquire()`, `takeOver()`, both claims, both
/// heartbeats) waits its turn at one gate and runs alone from its first read
/// to its last answer, in the order called, so no answer comes back to a
/// lease another call of this device has moved since it was sent. The one
/// thing that does not wait is `abandon()`, which has to take effect at
/// once: it moves `generation`, and an operation takes an answer as the
/// lease held (`hold`) only while the generation is the one it was called
/// under, and writes nothing more once it has moved. `isPrimary()` and
/// `held` only read, and do not wait: a probe is answered while a write is
/// out. A request that stalls would hold every call behind it, so each is
/// asked of the database bounded by `timing.patience`
/// (`RecordDatabase.answering(within:)`), and one that runs out is a
/// transport failure like any other: nothing is forgotten, and the write
/// may have landed after all. A renewal that did is found by the next call
/// as this instance's own, since nobody takes a lease without moving its
/// epoch: the record at the epoch held is the lease held, whatever its
/// version. A claim that did is not: the record names a device and an
/// endpoint, not an instance, so this device's lease at a later epoch this
/// instance has sent (`epochSent`) is its own claim or the claim of another
/// instance of the device, made where this one's never arrived, and nothing
/// tells the two apart. It is never taken as held. The instance stops
/// counting itself primary at once, yields to nobody, and its next
/// `acquire()` or `takeOver()` claims over that record as over any lease it
/// has not yielded to. The bound is a request's, so a network slower than
/// it loses every request, where an unbounded one would have been answered
/// late.
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
    /// The lease this device held when it was found lapsed locally, its
    /// heartbeats late, with no other device known to have claimed: what a
    /// batch may claim afresh over (`heartbeat(saving:)`). Nil once this
    /// device holds a lease again, has yielded, or has abandoned its claim.
    private var lapsedRecord: Record?
    /// The lease that took ours, while it stays fresh.
    private var yieldedTo: Lease?
    /// The epoch this instance held, or held when its lease lapsed, when a record that may be
    /// a claim of its own made it forget that lease (`disown`): what such a record is past
    /// while nothing is held. Nil once this device holds a lease again, has yielded, or has
    /// abandoned its claim.
    private var disownedAt: Int64?
    private var heartbeatTask: Task<Void, Never>?
    /// The highest epoch this instance has sent a write of, answered or not. A lease of this
    /// device's at an epoch past it was claimed by another instance; one at an epoch up to it,
    /// past the epoch held, may have been (`mayBeOwnClaim`).
    private var epochSent: Int64 = 0
    /// How many times the lease was abandoned. An operation reads it as it
    /// is called and checks it before every read and write it sends and
    /// before it takes an answer: an operation called before an `abandon()`
    /// writes nothing after it, and its answers hold nothing.
    private var generation = 0
    /// True while an operation is running; the rest wait in `waiting`, in order.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

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
        self.database = database.answering(within: timing.patience)
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
        let began = generation
        await enter()
        defer { leave() }
        for _ in 0..<3 {
            guard generation == began else { return .contended }
            let current = try await database.fetch(Lease.recordID)
            guard generation == began else { return .contended }

            guard let record = current else {
                if let lease = try await write(holder(epoch: 1), over: nil, began: began) { return .primary(lease) }
                continue
            }

            guard let lease = Lease(record: record) else {
                // A record that exists but does not parse blocks everyone
                // until someone claims over it. Nobody can be holding it.
                let epoch = (record.int("epoch") ?? 0) + 1
                if let mine = try await write(holder(epoch: epoch), over: record.changeTag, began: began) { return .primary(mine) }
                continue
            }

            if let mine = heldRecord, mine.changeTag != record.changeTag, isHeldLease(lease) {
                // The lease held, at a version this device has not heard of: a renewal of
                // its own that landed and was never answered. Nobody took anything, and the
                // server's version is the one to go over.
                heldRecord = record
            }

            if let mine = heldRecord {
                if mine.changeTag == record.changeTag {
                    if !lease.isExpired(at: now()) {
                        if let renewed = try await write(holder(epoch: lease.epoch), over: record.changeTag, began: began) {
                            return .primary(renewed)
                        }
                        continue
                    }
                    // Our own lease, lapsed without anyone taking it: a fresh claim.
                } else if mayBeOwnClaim(lease) {
                    // A claim this instance sent, or another instance's at the same epoch:
                    // nothing is held, and it is claimed over as any lease not yielded to.
                    disown()
                } else {
                    yield(to: lease)
                }
            }

            if lease.isExpired(at: now()) {
                if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag, began: began) { return .primary(mine) }
                continue
            }

            let alive = await probe.confirms(lease)
            guard generation == began else { return .contended }
            if alive {
                forget()
                return .held(by: lease)
            }

            if hasYielded(to: lease) {
                return .unreachable(lease)
            }

            if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag, began: began) { return .primary(mine) }
        }
        forget()
        return .contended
    }

    /// The hub's path: takes the lease from whoever holds it, live or not,
    /// without a probe. A hub is primary for as long as it is awake, so a
    /// phone holding the lease when the hub launches or wakes is displaced,
    /// learns so at its next heartbeat or turn, and yields. Nothing but the
    /// hub calls this; every other device goes through `acquire()`.
    public func takeOver() async throws -> LeaseOutcome {
        let began = generation
        await enter()
        defer { leave() }
        for _ in 0..<3 {
            guard generation == began else { return .contended }
            let current = try await database.fetch(Lease.recordID)
            guard generation == began else { return .contended }
            guard let record = current else {
                if let lease = try await write(holder(epoch: 1), over: nil, began: began) { return .primary(lease) }
                continue
            }
            guard let lease = Lease(record: record) else {
                let epoch = (record.int("epoch") ?? 0) + 1
                if let mine = try await write(holder(epoch: epoch), over: record.changeTag, began: began) { return .primary(mine) }
                continue
            }
            if let mine = heldRecord, mine.changeTag == record.changeTag, !lease.isExpired(at: now()) {
                if let renewed = try await write(holder(epoch: lease.epoch), over: record.changeTag, began: began) {
                    return .primary(renewed)
                }
                continue
            }
            // A claim this instance sent, or another instance's at the same epoch: nothing is
            // held by it while the claim over it is out.
            if mayBeOwnClaim(lease) { disown() }
            if let mine = try await write(holder(epoch: lease.epoch + 1), over: record.changeTag, began: began) { return .primary(mine) }
        }
        forget()
        return .contended
    }

    /// Claims over exactly the lapsed lease `record` the caller read: a compare-and-set on that
    /// version, so a heartbeat landing between the read and the claim is a conflict and the
    /// claim fails, rather than a claim over a holder that turned out to be alive. True when
    /// this device holds the lease afterwards. False, with nothing written, when the record is
    /// not a lapsed lease of another device or the version moved.
    public func claim(overLapsed record: Record) async throws -> Bool {
        let began = generation
        await enter()
        defer { leave() }
        guard let lease = Lease(record: record), lease.holder != device, lease.isExpired(at: now()) else { return false }
        return try await write(holder(epoch: lease.epoch + 1), over: record.changeTag, began: began) != nil
    }

    /// Stops counting this device primary and stops its heartbeats, without touching the
    /// record, which lapses on its own within one duration. For a claim whose owner cannot
    /// keep it (a takeover whose role records failed to land): the alternative is a lease
    /// renewed forever by nobody, which answers no turns and blocks every other device.
    /// It does not wait for the operations called before it, under way or waiting their turn:
    /// each writes nothing more, and what one already sent holds nothing here when it is
    /// answered.
    public func abandon() {
        generation += 1
        forget()
        disownedAt = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Creates the lease record for this device only if none exists: the
    /// atomic first claim, which exactly one of any number of devices
    /// launching together wins. True for the winner. The record is not held
    /// or heartbeated here; it lapses in one duration, and `acquire()` takes
    /// it properly when the first turn runs. False when a record exists,
    /// whoever holds it and however old, or when the lease was abandoned
    /// after this call was made.
    public func claimIfNone() async throws -> Bool {
        let began = generation
        await enter()
        defer { leave() }
        guard generation == began else { return false }
        do {
            _ = try await database.save(holder(epoch: 1).record(changeTag: nil))
            return generation == began
        } catch RecordDatabaseError.serverRecordChanged {
            return false
        }
    }

    /// Extends the held lease by one duration. Returns false, the lease no
    /// longer held, when the server holds a different version (another
    /// device has claimed it) or the lease has already expired locally (this
    /// device missed its heartbeats and is not primary until it claims again).
    /// A renewal of its own that landed unanswered is not a different
    /// version: it is taken as held and renewed over.
    /// True is this device primary as the call returns: a renewal answered
    /// after the duration it was good for is false.
    public func heartbeat() async throws -> Bool {
        let began = generation
        await enter()
        defer { leave() }
        guard generation == began, let record = heldRecord, let lease = Lease(record: record) else { return false }
        if hasLapsed(lease) {
            lapse()
            return false
        }
        guard try await write(holder(epoch: lease.epoch), over: record.changeTag, began: began) != nil else { return false }
        return isPrimary()
    }

    /// Saves `records` and a heartbeat of the held lease in one atomic batch,
    /// so the records land only if no other device has claimed the lease
    /// since this one last wrote it: a turn appended this way is never the
    /// work of a displaced brain. Returns the saved records, or nil with
    /// nothing applied when the lease is not held: never granted, abandoned
    /// before the save was sent, taken by another device (which this
    /// device then yields to, as after a failed heartbeat), found gone, or
    /// found at a later epoch that may be a claim of this instance's own
    /// (`mayBeOwnClaim`: disowned, with nothing yielded to), and when its
    /// own late renewals kept moving the record for three passes. A lease abandoned
    /// while the save was out leaves the records saved and returned, and
    /// nothing held. A conflict on any record but the lease propagates as
    /// the database threw it, again with nothing applied.
    ///
    /// A lease that lapsed locally, its heartbeats late, is not yet anyone
    /// else's. The record is read, and while it is still that lease (this
    /// device, the epoch it held, its endpoint) the batch carries a fresh
    /// claim over the version read, one epoch on, in place of the heartbeat:
    /// what a slow network cost is the lease's freshness, not the work done
    /// under it. A claim by another device since, before the read or between
    /// it and the save, refuses the batch as it refuses a heartbeat.
    ///
    /// Throws `CancellationError`, with nothing written, when the task was
    /// cancelled while the batch waited its turn or read the record.
    public func heartbeat(saving records: [Record]) async throws -> [Record]? {
        let began = generation
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        for _ in 0..<3 {
            guard generation == began else {
                Perf.mark("lease.batch.refused notHeld")
                return nil
            }
            let over: Record, claim: Lease
            if let record = heldRecord, let lease = Lease(record: record), !hasLapsed(lease) {
                (over, claim) = (record, holder(epoch: lease.epoch))
            } else {
                if heldRecord != nil { lapse() }
                guard let lapsed = lapsedRecord.flatMap(Lease.init(record:)) else {
                    Perf.mark("lease.batch.refused notHeld")
                    return nil
                }
                Perf.mark("lease.batch.lapsed")
                let server = try await database.fetch(Lease.recordID)
                try Task.checkCancellation()
                guard generation == began else {
                    Perf.mark("lease.batch.refused notHeld")
                    return nil
                }
                let current = server.flatMap(Lease.init(record:))
                guard let server, let current, current.holder == device, current.epoch == lapsed.epoch,
                      current.endpoint == endpoint else {
                    if let current, mayBeOwnClaim(current) {
                        // A claim this instance sent, or another instance's at the same
                        // epoch. Nothing is given up to it, and the batch is not that claim's;
                        // the next `acquire()` claims over it.
                        disown()
                        Perf.mark("lease.batch.refused notHeld")
                        return nil
                    }
                    Perf.mark("lease.batch.refused taken")
                    yield(to: current)
                    return nil
                }
                (over, claim) = (server, holder(epoch: current.epoch + 1))
            }
            let deadline = monotonic() + timing.duration
            epochSent = max(epochSent, claim.epoch)
            do {
                let saved = try await database.save(records + [claim.record(changeTag: over.changeTag)])
                // The records are in the log whatever became of the lease meanwhile.
                let tag = saved.first(where: { $0.id == Lease.recordID })?.changeTag
                _ = hold(claim.record(changeTag: tag), until: deadline, began: began)
                return saved.filter { $0.id != Lease.recordID }
            } catch RecordDatabaseError.serverRecordChanged(let id, let server) where id == Lease.recordID {
                guard generation == began else { return nil }
                let winner = Lease(record: server)
                if let winner, let mine = (heldRecord ?? lapsedRecord).flatMap(Lease.init(record:)),
                   winner.holder == device, winner.epoch == mine.epoch, winner.endpoint == endpoint {
                    // Still this device's lease, at a version it has not heard of: a write
                    // of its own that landed and was never answered. The batch goes again,
                    // a heartbeat over the server's version, a fresh claim after another read.
                    if heldRecord != nil { heldRecord = server }
                    continue
                }
                if let winner, mayBeOwnClaim(winner) {
                    // A claim this instance sent, or another instance's at the same epoch:
                    // not this batch's lease either way. Nothing is held and nothing is
                    // given up to it; the next `acquire()` claims over it.
                    disown()
                    Perf.mark("lease.batch.refused notHeld")
                    return nil
                }
                Perf.mark("lease.batch.refused taken")
                yield(to: winner)
                return nil
            } catch RecordDatabaseError.unknownItem(let id) where id == Lease.recordID {
                guard generation == began else { return nil }
                forget()
                return nil
            }
        }
        return nil
    }

    // MARK: One operation at a time

    /// Waits for the operations called before this one to finish. Every
    /// `enter()` is paired with a `leave()` on every path out.
    private func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next operation waiting, which finds it still
    /// busy, or opens it.
    private func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: What is held

    /// Takes `record`, a write of the lease that was just answered, as the
    /// lease held, good until `deadline`, and keeps it renewed. The only
    /// place an answered write becomes the lease held; a lease already held
    /// is moved to the server's version of it, its deadline unchanged, where
    /// a read or a conflict shows a write of this device's that was never
    /// answered. False, with nothing taken, when the lease was abandoned
    /// since the operation that sent the write was called.
    private func hold(_ record: Record, until deadline: TimeInterval, began: Int) -> Bool {
        guard generation == began else { return false }
        heldRecord = record
        heldUntil = deadline
        lapsedRecord = nil
        yieldedTo = nil
        disownedAt = nil
        startHeartbeats()
        return true
    }

    /// The held lease has lapsed locally. It is kept as the one a batch may
    /// claim afresh over, since nobody is known to have taken it.
    private func lapse() {
        lapsedRecord = heldRecord
        heldRecord = nil
    }

    /// This device no longer has the lease, held or lapsed.
    private func forget() {
        heldRecord = nil
        lapsedRecord = nil
    }

    /// Another lease stands where this device's was: it is given up, and
    /// that one is deferred to while it stays fresh.
    private func yield(to lease: Lease?) {
        forget()
        disownedAt = nil
        yieldedTo = lease
    }

    /// A record that may be a claim of this instance's stands where its lease was
    /// (`mayBeOwnClaim`): the lease is forgotten, held or lapsed, with nothing yielded to,
    /// and its epoch is kept as the one such a record is past.
    private func disown() {
        disownedAt = ownEpoch
        forget()
    }

    /// The epoch of the lease this instance holds, or held when it lapsed or was disowned.
    private var ownEpoch: Int64? {
        (heldRecord ?? lapsedRecord).flatMap(Lease.init(record:))?.epoch ?? disownedAt
    }

    private func holder(epoch: Int64) -> Lease {
        Lease(holder: device, endpoint: endpoint, epoch: epoch, expiresAt: now() + timing.duration)
    }

    /// True when `lease` is the lease held, at whatever version: this device's, at this
    /// endpoint, at the epoch held. Every claim moves the epoch on and a renewal goes only
    /// over the version its sender holds, so nothing but this instance's own renewals writes
    /// the record while it stays at the epoch this instance holds: a version of it this
    /// instance has not heard of is a renewal of its own that landed and was never answered.
    private func isHeldLease(_ lease: Lease) -> Bool {
        guard let mine = held else { return false }
        return lease.holder == device && lease.endpoint == endpoint && lease.epoch == mine.epoch
    }

    /// True when `lease` is this device's, at this endpoint, at an epoch past the one this
    /// instance holds, or held when its lease lapsed or was disowned (`ownEpoch`), and no
    /// later than one it has sent: a claim of its own that landed and was never answered, or
    /// the claim of another instance of this device made at an epoch this one sent and never
    /// landed. The record does not say which, so the caller disowns what it held, holds
    /// nothing by this record, and does not yield to it. False for an instance with no such
    /// epoch, which has held nothing or has yielded since: two cold instances creating the
    /// same lease look alike to each other, and one must lose.
    private func mayBeOwnClaim(_ lease: Lease) -> Bool {
        guard let mine = ownEpoch else { return false }
        return lease.holder == device && lease.endpoint == endpoint && lease.epoch > mine && lease.epoch <= epochSent
    }

    /// Same holder and epoch; the expiry moves with every heartbeat.
    private func hasYielded(to lease: Lease) -> Bool {
        guard let y = yieldedTo else { return false }
        return y.holder == lease.holder && y.epoch == lease.epoch
    }

    /// Compare-and-set of the lease record, by the operation that began
    /// under generation `began`. On success this device holds the saved
    /// version, its local deadline is set, and its heartbeats are running.
    /// On a conflict the lease is forgotten and the lease that won, written
    /// just now by a device that is evidently alive, is the one this device
    /// yields to. Unless the winner is the lease this device holds, at a
    /// version it has not heard of: a renewal of its own that landed and was
    /// never answered. The server's version is then the one held, and since
    /// no answer set a deadline for it the write goes once more over that
    /// version; `again` is false on that second go, which answers nil if it
    /// finds the same. A winner that may be a claim of this instance's
    /// (`mayBeOwnClaim`) is neither: the lease is forgotten and nothing is
    /// yielded to, nil. A record found gone under the version held forgets
    /// the lease; any other error propagates. Nil, with nothing sent or
    /// nothing taken, once the lease has been abandoned.
    private func write(_ lease: Lease, over changeTag: String?, began: Int, again: Bool = true) async throws -> Lease? {
        guard generation == began else { return nil }
        do {
            let deadline = monotonic() + timing.duration
            epochSent = max(epochSent, lease.epoch)
            let saved = try await database.save(lease.record(changeTag: changeTag))
            return hold(lease.record(changeTag: saved.changeTag), until: deadline, began: began) ? lease : nil
        } catch RecordDatabaseError.serverRecordChanged(_, let server) {
            guard generation == began else { return nil }
            let winner = Lease(record: server)
            if let winner, isHeldLease(winner) {
                heldRecord = server
                guard again else { return nil }
                return try await write(holder(epoch: lease.epoch), over: server.changeTag, began: began, again: false)
            }
            if let winner, mayBeOwnClaim(winner) {
                disown()
                return nil
            }
            yield(to: winner)
            return nil
        } catch RecordDatabaseError.unknownItem {
            guard generation == began else { return nil }
            if heldRecord?.changeTag == changeTag { forget() }
            return nil
        }
    }

    private func startHeartbeats() {
        guard heartbeatTask == nil else { return }
        let loop = generation
        heartbeatTask = Task { await runHeartbeats(loop) }
    }

    /// Renews the lease held until it is lost. A loop outlived by an
    /// `abandon()` ends at its next step and leaves the handle alone, which
    /// by then is nil or a later loop's.
    private func runHeartbeats(_ loop: Int) async {
        defer { if generation == loop { heartbeatTask = nil } }
        while heldRecord != nil, generation == loop, !Task.isCancelled {
            do { try await sleep(timing.heartbeat) } catch { return }
            guard heldRecord != nil, generation == loop else { return }
            // A transport failure is not a lost lease; the local expiry decides.
            let began = monotonic()
            let outcome: String
            do { outcome = try await heartbeat() ? "held" : "lost" } catch { outcome = "failed" }
            Perf.mark("lease.heartbeat \(outcome) ms=\(Int((monotonic() - began) * 1000))")
        }
    }
}
