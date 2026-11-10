import Foundation
import Testing
import TopoCore
import TopoCoreTesting

/// The bounded double the lease's patience test stands on: what it holds, what it gives up, and
/// what a release answers.
@Suite struct HoldingDatabaseTests {
    /// Two saves held at once, the first given up at its bound before the second was armed: one
    /// release answers both, and neither is left suspended.
    @Test func everySaveHeldIsAnsweredByOneRelease() async throws {
        let held = HoldingDatabase(InMemoryRecordDatabase())
        let bounded = held.answering(within: 0.05)
        held.holdNextSave()
        let ranOut = await givenUp(held) { try await bounded.save([Record(type: "T", id: RecordID("a"))]) }
        #expect(unavailable(ranOut))
        try await until("the save the bound gave up is still out") { held.held == 1 }
        held.holdNextSave()
        let second = Task { try await held.save([Record(type: "T", id: RecordID("b"))]) }
        try await until { held.held == 2 }
        held.release()
        let answered = await #expect(throws: RecordDatabaseError.self) { try await second.value }
        #expect(unavailable(answered), "a save held unlanded answers unavailable")
        try await until("a held save left suspended") { held.held == 0 && held.answered == 2 }
        #expect(held.answered == 2, "both held saves answered the one release")
    }

    /// A landing save is in the store at once; the bounded view gives the answer up at its
    /// bound, and the release answers the save as the store did.
    @Test func aLandingSaveIsStoredAndOnlyItsAnswerHeld() async throws {
        let inner = InMemoryRecordDatabase()
        let held = HoldingDatabase(inner)
        held.holdNextSave(landing: true)
        let bounded = held.answering(within: 0.05)
        let ranOut = await givenUp(held) { try await bounded.save([Record(type: "T", id: RecordID("a"))]) }
        #expect(unavailable(ranOut))
        try await until("the request is still out after the bound gave it up") { held.holding }
        #expect(try await inner.fetch([RecordID("a")])[RecordID("a")] != nil, "the save landed")
        held.release()
        try await until { !held.holding }
    }

    /// A landing save asked unbounded answers the release with the record the store saved.
    @Test func aLandingSaveAnswersItsReleaseWithTheRecord() async throws {
        let held = HoldingDatabase(InMemoryRecordDatabase())
        held.holdNextSave(landing: true)
        let save = Task { try await held.save([Record(type: "T", id: RecordID("a"))]) }
        try await until { held.held == 1 }
        held.release()
        let saved = try await save.value
        #expect(saved.map(\.id) == [RecordID("a")])
        #expect(saved.first?.changeTag != nil, "the answer is the stored record, tag and all")
    }

    /// A held fetch is given up at the view's bound, no sooner and not at some bound of its own,
    /// and still out until the release, which lets it read the store.
    @Test func aHeldFetchGivesUpAtItsBound() async throws {
        let inner = InMemoryRecordDatabase()
        _ = try await inner.save([Record(type: "T", id: RecordID("a"))])
        let held = HoldingDatabase(inner)
        held.holdNextFetch()
        let bounded = held.answering(within: 0.2)
        let start = ContinuousClock.now
        let ranOut = await givenUp(held) { try await bounded.fetch([RecordID("a")]) }
        let waited = ContinuousClock.now - start
        #expect(unavailable(ranOut))
        #expect(waited >= .milliseconds(200), "given up before its bound, after \(waited)")
        #expect(waited < .milliseconds(900), "given up long after its bound, after \(waited)")
        try await until("the fetch the bound gave up is still out") { held.held == 1 }
        #expect(held.answered == 0)
        held.release()
        try await until { held.answered == 1 }
        #expect(try await bounded.fetch([RecordID("a")])[RecordID("a")] != nil, "the next fetch is not held")
    }
}

/// The error `work` threw, a request through the bounded view; one still unanswered after 2 s is a
/// view that never gave it up, so it is released and recorded rather than left to hang the run.
private func givenUp<T: Sendable>(
    _ held: HoldingDatabase, _ work: @escaping @Sendable () async throws -> T
) async -> RecordDatabaseError? {
    let request = Task { try await work() }
    let watchdog = Task {
        guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
        Issue.record("the bound never gave the request up")
        held.release()
    }
    defer { watchdog.cancel() }
    do { _ = try await request.value } catch { return error as? RecordDatabaseError }
    return nil
}

private func unavailable(_ error: RecordDatabaseError?) -> Bool {
    if case .unavailable? = error { true } else { false }
}

private func until(_ what: String = "timed out", _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record(Comment(rawValue: what)); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}
