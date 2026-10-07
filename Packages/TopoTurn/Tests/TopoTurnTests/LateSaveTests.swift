import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// The next save that carries a person's turn fails `unavailable` and is still on its way: it
/// lands just ahead of the next save that carries a turn. A request that ran out, applied late.
actor LandsLate: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var armed = false
    private var late: [Record]?
    func arm() { armed = true }
    func save(_ records: [Record]) async throws -> [Record] {
        if armed, records.contains(where: { Turn(record: $0)?.role == .person }) {
            armed = false
            late = records
            throw RecordDatabaseError.unavailable(underlying: Refused())
        }
        if records.contains(where: { $0.type == Turn.recordType }), let landing = late {
            late = nil
            _ = try await wrapped.save(landing)
        }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

@Suite struct LateSaveTests {
    @Test(arguments: [true, false]) func aRetryWhoseEarlierSaveLandsAfterItsReadIsNotMovedPast(more: Bool) async throws {
        let db = LandsLate()
        let brain = ScriptedBrain(.success("to hello"), .success("to once"), .success("to second"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, standing: .mine)
        _ = try await runner.run("hello", model: .sonnet5, nonce: "n0", known: [])
        await db.arm()
        do {
            _ = try await runner.run("once", model: .sonnet5, nonce: "n1", known: [])
            Issue.record("control: the first attempt's save was expected to fail")
        } catch TurnRunnerError.unsaved {}
        #expect(try await TurnLog(database: db).read().ordered.map(\.text) == ["hello", "to hello"], "control: not landed yet")
        var movedPast = false
        do {
            _ = try await runner.run("once", model: .sonnet5, nonce: "n1", known: [])
        } catch {
            // By name, so the same file compiles against the runner before `movedPast` existed.
            movedPast = "\(error)".hasPrefix("movedPast")
            if !movedPast { Issue.record("the retry failed some other way: \(error)") }
        }
        let after = try await TurnLog(database: db).read()
        let once = try #require(after.ordered.first { $0.nonce == "n1" })
        #expect(after.heads == [movedPast ? once.ref : after.heads[0]], "control")
        #expect(!movedPast, "a retry whose turn is the log's one head, with nothing after it, was told the log moved past it")
        // What the harness does on movedPast: the line entry is settled, and the next goes.
        if more { _ = try await runner.run("second", model: .sonnet5, nonce: "n2", known: []) }
        _ = try await runner.answerPending(model: .sonnet5)
        let end = try await TurnLog(database: db).read()
        #expect(end.ordered.contains { $0.role == .assistant && $0.parents == [once.ref] },
                "the turn has no reply and is no head: \(end.ordered.map(\.text)), heads \(end.heads.compactMap { end[$0]?.text })")
        #expect(brain.bound.map(\.nonce).contains("n1"), "the words the brain heard were never bound to their turn")
    }
}
