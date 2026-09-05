import CloudKit
import Foundation

/// The three things Womble asks of CloudKit. Small on purpose: it is the
/// seam the tests read a hidden tail through, and the only place that knows
/// about containers and zones.
///
/// Every completion may run on any queue; the caller hops to the main queue
/// once, at the end.
protocol TurnRecordStore: AnyObject {
    /// Succeeds when there is an iCloud account to read from.
    func accountAvailable(_ completion: @escaping (Result<Void, TranscriptError>) -> Void)
    /// Every turn record the query index knows about.
    func queryTurns(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void)
    /// Which of these record names exist, fetched by ID. A name that is not
    /// there is absent from the result rather than an error.
    func fetchTurns(named names: [String], _ completion: @escaping (Result<Set<String>, TranscriptError>) -> Void)
}
