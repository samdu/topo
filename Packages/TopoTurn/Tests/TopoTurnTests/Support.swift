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

    func landed(_ reply: Turn, nonce: String) async {
        lock.withLock { if _owes?.nonce == nonce { _owes = nil } }
    }

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
                probe: any LeaseProbe = NoSocketProbe(), clock: Elapsed? = nil) async throws -> (TurnRunner, PrimaryLease) {
    let id = DeviceID(device)
    let log = TurnLog(database: database)
    let writer = try await log.writer(for: id)
    let sleep: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    let lease = if let clock {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, now: clock.now, monotonic: clock.uptime, sleep: sleep)
    } else {
        PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, sleep: sleep)
    }
    return (TurnRunner(log: log, writer: writer, lease: lease, brain: brain), lease)
}
