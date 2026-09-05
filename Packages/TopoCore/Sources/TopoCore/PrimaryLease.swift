import Foundation

/// The one mutable record: who is primary right now.
///
/// `epoch` goes up by one on every claim, so a holder can tell its own lease
/// from a later one on the same device. `endpoint` is where the holder
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

/// Asks a lease holder whether it is alive. The implementation owns the
/// transport and the timeout; it returns false on no answer.
public protocol LeaseProbe: Sendable {
    func answers(_ lease: Lease) async -> Bool
}

public struct LeaseTiming: Hashable, Sendable {
    /// How long a claim or heartbeat is good for.
    public var duration: TimeInterval
    /// How often a holder should heartbeat. Half the duration, so one missed
    /// heartbeat does not lose the lease.
    public var heartbeat: TimeInterval

    public init(duration: TimeInterval = 10, heartbeat: TimeInterval = 5) {
        self.duration = duration
        self.heartbeat = heartbeat
    }

    public static let standard = LeaseTiming()
}

public enum LeaseOutcome: Hashable, Sendable {
    /// This device holds the lease.
    case primary(Lease)
    /// Another device holds it and answered the probe.
    case held(by: Lease)
    /// The record kept changing under us. Try again next turn.
    case contended
}

/// Claims, keeps and yields the primary lease for one device.
///
/// Handover is probe-driven. `acquire()` is the turn-time path: it reads the
/// lease, and if another device holds it, probes that device and claims
/// only on no answer, so a dead holder costs one probe timeout. The expiry
/// exists to stop two claimants racing: every write is a compare-and-set on
/// the record's tag, so of two claimants one wins and the other re-reads,
/// sees a fresh lease, probes the winner and defers. A holder that cannot
/// heartbeat stops counting itself primary when its lease expires
/// (`isPrimary()`), so a device that claimed over a failed probe is alone
/// within one duration even if the old holder is only partitioned.
///
/// There is no release. A holder that goes away is found by the next probe.
public actor PrimaryLease {
    private let database: any RecordDatabase
    private let device: DeviceID
    private let endpoint: String?
    private let probe: any LeaseProbe
    private let timing: LeaseTiming
    private let now: @Sendable () -> Date

    /// The lease record this device last successfully wrote, if any.
    private var heldRecord: Record?

    public init(database: any RecordDatabase, device: DeviceID, endpoint: String?,
                probe: any LeaseProbe, timing: LeaseTiming = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.device = device
        self.endpoint = endpoint
        self.probe = probe
        self.timing = timing
        self.now = now
    }

    /// The lease this device holds, or nil.
    public var held: Lease? { heldRecord.flatMap(Lease.init(record:)) }

    /// True while this device holds an unexpired lease. Needs no network:
    /// a holder that has not managed a heartbeat inside the duration is not
    /// primary, whatever the server says.
    public func isPrimary() -> Bool {
        guard let lease = held else { return false }
        return !lease.isExpired(at: now())
    }

    /// The turn-time path. Returns `.primary` when this device holds the
    /// lease afterwards, whether by keeping, retaking or claiming it.
    public func acquire() async throws -> LeaseOutcome {
        for _ in 0..<3 {
            let now = now()
            let current = try await database.fetch(Lease.recordID)
            guard let record = current, let lease = Lease(record: record) else {
                if try await write(Lease(holder: device, endpoint: endpoint, epoch: 1,
                                         expiresAt: now + timing.duration), over: nil) {
                    return .primary(held!)
                }
                continue
            }
            if lease.holder == device {
                if try await write(Lease(holder: device, endpoint: endpoint, epoch: lease.epoch,
                                         expiresAt: now + timing.duration), over: record.changeTag) {
                    return .primary(held!)
                }
                continue
            }
            if !lease.isExpired(at: now), await probe.answers(lease) {
                heldRecord = nil
                return .held(by: lease)
            }
            if try await write(Lease(holder: device, endpoint: endpoint, epoch: lease.epoch + 1,
                                     expiresAt: now + timing.duration), over: record.changeTag) {
                return .primary(held!)
            }
        }
        heldRecord = nil
        return .contended
    }

    /// Extends the held lease by one duration. Returns false, and forgets
    /// the lease, when the server holds a different version: another device
    /// has claimed it, and this device is no longer primary.
    public func heartbeat() async throws -> Bool {
        guard let record = heldRecord, let lease = Lease(record: record) else { return false }
        return try await write(Lease(holder: device, endpoint: endpoint, epoch: lease.epoch,
                                     expiresAt: now() + timing.duration), over: record.changeTag)
    }

    /// Compare-and-set of the lease record. On success `heldRecord` is the
    /// saved version; on a conflict it is cleared. Anything but a conflict
    /// propagates.
    private func write(_ lease: Lease, over changeTag: String?) async throws -> Bool {
        do {
            heldRecord = try await database.save(lease.record(changeTag: changeTag))
            return true
        } catch RecordDatabaseError.serverRecordChanged {
            heldRecord = nil
            return false
        } catch RecordDatabaseError.unknownItem {
            heldRecord = nil
            return false
        }
    }
}
