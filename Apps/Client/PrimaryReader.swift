import Foundation
import Observation
import TopoCore

/// Who is primary, read and never claimed.
///
/// A viewer asks this only so it can say what it is connected to. The TV in
/// particular never offers to be primary, so it reads the lease record and
/// writes nothing: no claim, no heartbeat, no probe.
@MainActor
@Observable
final class PrimaryReader {
    /// The lease as the record last had it, expired or not.
    private(set) var lease: Lease?
    /// True while that lease has not lapsed. An expired lease means the
    /// device that held it stopped heartbeating: nothing is primary.
    private(set) var isFresh = false

    private let database: any RecordDatabase

    init(database: any RecordDatabase) {
        self.database = database
    }

    func refresh(now: Date = Date()) async {
        guard let record = try? await database.fetch(Lease.recordID), let lease = Lease(record: record) else {
            self.lease = nil
            self.isFresh = false
            return
        }
        self.lease = lease
        self.isFresh = !lease.isExpired(at: now)
    }
}
