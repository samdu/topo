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

    init(_ answers: Result<String, any Error>...) { self.answers = answers }

    var requests: [BrainRequest] { lock.withLock { _requests } }

    func answer(_ request: BrainRequest) async throws -> Reply {
        lock.withLock { _requests.append(request) }
        await duringAnswer?()
        let next = lock.withLock { answers.isEmpty ? .failure(Refused()) : answers.removeFirst() }
        return Reply(text: try next.get(), model: request.model.rawValue, context: 0, outputTokens: 0)
    }

    func describe() async -> String { "scripted" }
}

/// What a scripted brain throws for a failed answer.
struct Refused: Error, Equatable {}

struct AlwaysConfirms: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}

/// A runner over an in-memory log for one device, with a lease it can always take.
func makeRunner(database: any RecordDatabase, device: String = "phone", brain: ScriptedBrain,
                probe: any LeaseProbe = NoSocketProbe()) async throws -> (TurnRunner, PrimaryLease) {
    let id = DeviceID(device)
    let log = TurnLog(database: database)
    let writer = try await log.writer(for: id)
    let lease = PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    return (TurnRunner(log: log, writer: writer, lease: lease, brain: brain), lease)
}
