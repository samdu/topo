import Foundation
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// A brain that answers from a queue and records every request it was asked.
final class ScriptedBrain: Brain, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<String, any Error>]
    private var _requests: [BrainRequest] = []
    /// Runs while a request is being answered, before its reply.
    var duringAnswer: (@Sendable () async -> Void)?

    init(_ answers: Result<String, any Error>...) { self.answers = answers }

    var requests: [BrainRequest] { lock.withLock { _requests } }

    func answer(_ request: BrainRequest) async throws -> Reply {
        lock.withLock { _requests.append(request) }
        await duringAnswer?()
        let next = lock.withLock { answers.isEmpty ? .failure(Refused()) : answers.removeFirst() }
        return Reply(text: try next.get(), model: request.model.rawValue, context: 0, outputTokens: 0)
    }

    func describe() async -> String { "scripted" }

    /// A reply this brain says the log is owed, until it lands.
    var owedReply: OwedReply? {
        get { lock.withLock { _owed } }
        set { lock.withLock { _owed = newValue } }
    }
    private var _owed: OwedReply?
    func owed() async -> OwedReply? { owedReply }
    func landed(_ turn: Turn, nonce: String) async { if owedReply?.nonce == nonce { owedReply = nil } }
}

/// What a scripted brain throws for a failed answer.
struct Refused: Error, Equatable {}

struct AlwaysConfirms: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}

/// Records what reaches the store: the IDs of each fetch and the types of each saved batch.
final class RecordingDatabase: RecordDatabase, @unchecked Sendable {
    let inner: InMemoryRecordDatabase
    private let lock = NSLock()
    private var _fetched: [[RecordID]] = []
    private var _saved: [[String]] = []
    init(inner: InMemoryRecordDatabase) { self.inner = inner }
    var leaseFetches: Int { lock.withLock { _fetched.count { $0.contains(Lease.recordID) } } }
    var saved: [[String]] { lock.withLock { _saved } }
    func reset() { lock.withLock { _fetched = []; _saved = [] } }
    func save(_ records: [Record]) async throws -> [Record] {
        let out = try await inner.save(records)
        lock.withLock { _saved.append(records.map(\.type)) }
        return out
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        lock.withLock { _fetched.append(ids) }
        return try await inner.fetch(ids)
    }
    func records(ofType type: String) async throws -> [Record] { try await inner.records(ofType: type) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private let start = Date()
    var now: Date { lock.withLock { start.addingTimeInterval(offset) } }
    var uptime: TimeInterval { lock.withLock { offset } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

/// A runner over an in-memory log for one device, with a lease it can always take.
func makeRunner(database: any RecordDatabase, device: String = "phone", brain: ScriptedBrain,
                probe: any LeaseProbe = NoSocketProbe(), clock: TestClock? = nil) async throws -> (TurnRunner, PrimaryLease) {
    let id = DeviceID(device)
    let log = TurnLog(database: database)
    let writer = try await log.writer(for: id)
    let never: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    let lease = if let clock {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe,
                     now: { clock.now }, monotonic: { clock.uptime }, sleep: never)
    } else {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, sleep: never)
    }
    return (TurnRunner(log: log, writer: writer, lease: lease, brain: brain), lease)
}
