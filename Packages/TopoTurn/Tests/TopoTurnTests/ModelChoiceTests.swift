import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// The person's choice of model in the zone, and the answering pass that asks it.
@Suite struct ModelChoiceTests {
    @Test func aChoiceIsSaidOnceAndReadAsTheFamily() async throws {
        let db = InMemoryRecordDatabase()
        #expect(try await ModelChoice.read(from: db) == nil)
        try await ModelChoice.say(.opus, by: DeviceID("ios-1a2b3c4d"), to: db)
        #expect(try await ModelChoice.read(from: db) == .opus)
        let tag = await db.current(ModelChoice.recordID)?.changeTag
        // Said again: nothing written.
        try await ModelChoice.say(.opus, by: DeviceID("ios-1a2b3c4d"), to: db)
        #expect(await db.current(ModelChoice.recordID)?.changeTag == tag)
        // Another device's choice replaces it.
        try await ModelChoice.say(.fable, by: DeviceID("ios-99999999"), to: db)
        #expect(try await ModelChoice.read(from: db) == .fable)
        #expect(await db.current(ModelChoice.recordID)?.string("device") == "ios-99999999")
    }

    @Test func aRecordThatNamesNoChoiceIsNone() async throws {
        let db = InMemoryRecordDatabase()
        for kept in ["claude-haiku-5-5", "gpt", ""] {
            let current = await db.current(ModelChoice.recordID)
            _ = try await db.save([Record(type: ModelChoice.recordType, id: ModelChoice.recordID,
                                          fields: ["model": .string(kept)], changeTag: current?.changeTag)])
            #expect(try await ModelChoice.read(from: db) == nil, "\(kept)")
        }
    }

    /// A say that loses to another device's write reads again and goes over it.
    @Test func aSayOverAMovedRecordGoesOverTheNewVersion() async throws {
        let db = InMemoryRecordDatabase()
        try await ModelChoice.say(.sonnet, by: DeviceID("a"), to: db)
        let racing = RacingWrite(db)
        try await ModelChoice.say(.opus, by: DeviceID("b"), to: racing)
        #expect(try await ModelChoice.read(from: db) == .opus)
    }

    /// The answering pass asks for the model once it has a turn to answer, and the request carries
    /// what it was given; a pass with nothing to answer asks nothing.
    @Test func thePassAsksTheChoiceOnlyWhenItAnswers() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("hi"))
        let (runner, _) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        let asked = Counter()
        #expect(try await runner.answerPending(choosing: { asked.bump(); return .fable }) == nil)
        #expect(asked.value == 0)
        let log = TurnLog(database: db)
        _ = try await log.writer(for: DeviceID("ios-1a2b3c4d")).append(.person, "hello", continuing: try await log.read())
        #expect(try await runner.answerPending(choosing: { asked.bump(); return .fable }) != nil)
        #expect(asked.value == 1)
        #expect(brain.requests.map(\.model) == [.fable])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// The first save of the choice finds another device's write landed first.
final class RacingWrite: ForwardingDatabase, @unchecked Sendable {
    let inner: InMemoryRecordDatabase
    var base: any RecordDatabase { inner }
    private let lock = NSLock()
    private var raced = false
    init(_ inner: InMemoryRecordDatabase) { self.inner = inner }

    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let race = lock.withLock { defer { raced = true }; return !raced }
        if race, let current = await inner.current(ModelChoice.recordID) {
            _ = try await inner.save([Record(type: ModelChoice.recordType, id: ModelChoice.recordID,
                                             fields: ["model": .string("fable")], changeTag: current.changeTag)])
        }
        return try await base.save(records)
    }
}
