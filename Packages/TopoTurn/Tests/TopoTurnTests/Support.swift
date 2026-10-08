import Foundation
import TopoCore
@testable import TopoTurn

/// A brain that answers from a queue and records every request it was asked.
final class ScriptedBrain: Brain, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<String, any Error>]
    private var _requests: [BrainRequest] = []
    /// Runs while a request is being answered, before its reply.
    var duringAnswer: (@Sendable () async -> Void)?
    private var _owes: OwedReply?
    /// A reply this brain finished that the log does not hold, until it hears it has landed.
    var owes: OwedReply? {
        get { lock.withLock { _owes } }
        set { lock.withLock { _owes = newValue } }
    }

    init(_ answers: Result<String, any Error>...) { self.answers = answers }

    var requests: [BrainRequest] { lock.withLock { _requests } }

    func answer(_ request: BrainRequest) async throws -> Reply {
        lock.withLock { _requests.append(request) }
        await duringAnswer?()
        let next = lock.withLock { answers.isEmpty ? .failure(Refused()) : answers.removeFirst() }
        return Reply(text: try next.get(), model: request.model.rawValue, context: 0, outputTokens: 0)
    }

    func owed() async -> OwedReply? { owes }

    /// Whether this brain takes words ahead of their turn. Off, it is a brain that only answers.
    var hears = false
    private var _heard: [(words: String, nonce: String, context: [Turn]?)] = []
    private var _bound: [(nonce: String, person: Turn, reply: String)] = []
    var heard: [(words: String, nonce: String, context: [Turn]?)] { lock.withLock { _heard } }
    var bound: [(nonce: String, person: Turn, reply: String)] { lock.withLock { _bound } }

    func hear(_ words: String, nonce: String, context: [Turn]?, model: ClaudeModel) async -> Bool {
        guard hears else { return false }
        lock.withLock { if !_heard.contains(where: { $0.nonce == nonce }) { _heard.append((words, nonce, context)) } }
        return true
    }

    func bind(nonce: String, person: Turn, reply: String) async {
        lock.withLock { _bound.append((nonce, person, reply)) }
    }

    func landed(_ reply: Turn, nonce: String) async {
        lock.withLock {
            if _owes?.nonce == nonce { _owes = nil }
            _landed.append(nonce)
        }
    }

    private var _landed: [String] = []
    /// The reply nonces this brain heard had landed, in order.
    var landedNonces: [String] { lock.withLock { _landed } }

    func describe() async -> String { "scripted" }
}

/// What a scripted brain throws for a failed answer.
struct Refused: Error, Equatable {}

struct AlwaysConfirms: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}

/// Time a test moves by hand: the lease's wall clock and its monotonic one together.
final class Elapsed: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
    var now: @Sendable () -> Date { { [self] in Date(timeIntervalSince1970: 1_800_000_000 + lock.withLock { seconds }) } }
    var uptime: @Sendable () -> TimeInterval { { [self] in lock.withLock { seconds } } }
}

/// A runner over an in-memory log for one device, with a lease it can always take. `clock`, when
/// given, is the lease's time, which no heartbeat moves: the lease's own sleep never returns.
func makeRunner(database: any RecordDatabase, device: String = "phone", brain: ScriptedBrain,
                probe: any LeaseProbe = NoSocketProbe(), clock: Elapsed? = nil,
                standing: TurnRunner.Standing = .unknown) async throws -> (TurnRunner, PrimaryLease) {
    let id = DeviceID(device)
    let log = TurnLog(database: database)
    let writer = try await log.writer(for: id)
    let sleep: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    let lease = if let clock {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, now: clock.now, monotonic: clock.uptime, sleep: sleep)
    } else {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, sleep: sleep)
    }
    return (TurnRunner(log: log, writer: writer, lease: lease, brain: brain, standing: standing), lease)
}

/// A database that can be taken away: while `away`, every call fails `unavailable` and nothing
/// reaches the store, which is CloudKit unreachable.
final class Outage: RecordDatabase, @unchecked Sendable {
    private let base: any RecordDatabase
    private let lock = NSLock()
    private var _away = false
    var away: Bool {
        get { lock.withLock { _away } }
        set { lock.withLock { _away = newValue } }
    }

    init(_ base: any RecordDatabase) { self.base = base }

    private func reach() throws {
        if away { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
    }

    func save(_ records: [Record]) async throws -> [Record] { try reach(); return try await base.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try reach(); return try await base.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try reach(); return try await base.query(query) }
    func records(ofType type: String) async throws -> [Record] { try reach(); return try await base.records(ofType: type) }
}
