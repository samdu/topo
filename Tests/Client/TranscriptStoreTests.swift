import TopoCore
import TopoCoreTesting
import TopoLink
import XCTest

@testable import Topo

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private let device = DeviceID("watch-test")

    /// Defaults of its own per test, so a remembered send in one does not
    /// reach another — and so the suite never writes to the real ones.
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
        return defaults
    }

    private func store(_ database: any RecordDatabase,
                       ensureZone: @escaping @Sendable () async throws -> Void = {},
                       defaults: UserDefaults? = nil) -> TranscriptStore {
        TranscriptStore(database: database, device: device, ensureZone: ensureZone,
                        defaults: defaults ?? makeDefaults())
    }

    /// Puts turns in the log the way another device would have.
    private func write(_ database: any RecordDatabase, _ lines: [(TurnRole, String)],
                       device: DeviceID = DeviceID("phone")) async throws {
        let writer = try await TurnLog(database: database).writer(for: device)
        var parents: [TurnRef] = []
        for (index, line) in lines.enumerated() {
            let turn = try await writer.append(line.0, line.1, parents: parents,
                                               at: Date(timeIntervalSince1970: TimeInterval(index + 1)))
            parents = [turn.ref]
        }
    }

    func testASentTurnAsksThePrimaryOverTheLANAndShowsTheReplyBeforeTheReadHasIt() async throws {
        let database = InMemoryRecordDatabase()
        // A primary with an endpoint holds the lease.
        let phone = DeviceID("phone")
        let holder = PrimaryLease(database: database, device: phone, endpoint: "10.0.0.2:4242", probe: AlwaysAlive(),
                                  sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await holder.acquire() else { return XCTFail("claim") }
        let asked = Asked()
        let replyRef = TurnRef(device: phone, sequence: 1)
        let store = TranscriptStore(database: database, device: device, ensureZone: {}, defaults: makeDefaults(),
                                    ask: { endpoint, ref in
                                        await asked.note(endpoint, ref)
                                        return LiveReply(ref: replyRef, text: "at once")
                                    })
        await store.send("now?")
        let calls = await asked.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "10.0.0.2:4242")
        XCTAssertEqual(calls.first?.1, TurnRef(device: device, sequence: 1))
        // The reply shows before any record of it exists, and survives a read without it.
        XCTAssertEqual(store.turns.map(\.text), ["now?", "at once"])
        await store.refresh()
        XCTAssertEqual(store.turns.map(\.text), ["now?", "at once"])
        // Once the primary's record lands, the read's copy is the one shown, once.
        let writer = try await TurnLog(database: database).writer(for: phone)
        _ = try await writer.append(.assistant, "at once", parents: [TurnRef(device: device, sequence: 1)])
        await store.refresh()
        XCTAssertEqual(store.turns.map(\.text), ["now?", "at once"])
        XCTAssertEqual(store.turns.last?.ref, replyRef)
    }

    func testNoPrimaryEndpointMeansNoAskAndTheLogPathStands() async throws {
        let database = InMemoryRecordDatabase()
        let asked = Asked()
        let store = TranscriptStore(database: database, device: device, ensureZone: {}, defaults: makeDefaults(),
                                    ask: { endpoint, ref in await asked.note(endpoint, ref); return nil })
        await store.send("hello")
        let calls = await asked.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.turns.map(\.text), ["hello"])
    }

    func testReadsTheLogInOrder() async throws {
        let database = InMemoryRecordDatabase()
        try await write(database, [(.person, "first"), (.assistant, "second")])

        let store = store(database)
        await store.refresh()

        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.turns.map(\.text), ["first", "second"])
        XCTAssertNil(store.notice)
    }

    func testAnEmptyLogIsReadyAndEmpty() async {
        let store = store(InMemoryRecordDatabase())
        await store.refresh()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertTrue(store.turns.isEmpty)
    }

    func testSendingAppendsAPersonTurnFromThisDevice() async throws {
        let database = InMemoryRecordDatabase()
        try await write(database, [(.person, "first"), (.assistant, "second")])
        let store = store(database)
        await store.refresh()

        await store.send("  what did I forget  ")

        XCTAssertEqual(store.turns.map(\.text), ["first", "second", "what did I forget"])
        let last = try XCTUnwrap(store.turns.last)
        XCTAssertEqual(last.role, .person, "a limb writes the person's turn, never the assistant's")
        XCTAssertEqual(last.ref.device, device)
        XCTAssertEqual(last.parents, [store.turns[1].ref], "it continues from the head it read")
        XCTAssertNil(store.notice)
    }

    func testSendingNothingWritesNothing() async {
        let database = InMemoryRecordDatabase()
        let store = store(database)
        await store.send("   ")
        await store.refresh()
        XCTAssertTrue(store.turns.isEmpty)
    }

    func testAFailedZoneCreationIsSaidAndTheTurnIsKept() async {
        let database = InMemoryRecordDatabase()
        let store = store(database, ensureZone: { throw RecordDatabaseError.unavailable(underlying: CancellationError()) })

        await store.send("hello")

        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertEqual(store.outbox, ["hello"], "nothing said is dropped")
        XCTAssertNotNil(store.notice, "a send that did not land says so")
    }

    func testAForkIsSaid() async throws {
        let database = InMemoryRecordDatabase()
        let log = TurnLog(database: database)
        let phone = try await log.writer(for: DeviceID("phone"))
        let root = try await phone.append(.person, "root", parents: [], at: Date(timeIntervalSince1970: 1))
        _ = try await phone.append(.assistant, "left", parents: [root.ref], at: Date(timeIntervalSince1970: 2))
        let hub = try await log.writer(for: DeviceID("hub"))
        _ = try await hub.append(.assistant, "right", parents: [root.ref], at: Date(timeIntervalSince1970: 3))

        let store = store(database)
        await store.refresh()

        XCTAssertEqual(store.turns.count, 3, "both branches are shown")
        XCTAssertEqual(store.notice, "Two devices carried on from the same point. Both are below.")
    }

    func testARetryAfterALostAcknowledgementDoesNotWriteTheTurnTwice() async throws {
        // CloudKit can lose the acknowledgement and keep the write. The
        // person presses send again; the same nonce recovers the turn that
        // is already there rather than saying it twice.
        let database = FailingDatabase(InMemoryRecordDatabase())
        let store = store(database)
        await database.setFailAfterSave(true)

        await store.send("call Helen")

        XCTAssertEqual(store.outbox, ["call Helen"], "the send is queued because it was not acknowledged")
        await database.setFailAfterSave(false)
        await store.flush()

        XCTAssertEqual(store.turns.map(\.text), ["call Helen"], "one turn, not two")
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testDifferentWordsAreADifferentTurn() async throws {
        let database = FailingDatabase(InMemoryRecordDatabase())
        let store = store(database)
        await database.setFailAfterSave(true)
        await store.send("call Helen")
        await database.setFailAfterSave(false)

        await store.send("call Helen back")

        XCTAssertEqual(store.turns.map(\.text), ["call Helen", "call Helen back"],
                       "the first turn committed; the second is a new thing said")
    }

    func testSayingSomethingNewDoesNotDropWhatDidNotSend() async throws {
        // A turn that failed outright is still owed. Speaking again queues
        // behind it rather than taking its place.
        let database = FailingDatabase(InMemoryRecordDatabase())
        let store = store(database)
        await database.setFailure(RecordDatabaseError.unavailable(underlying: CancellationError()))

        await store.send("call Helen")
        await store.send("and book the flights")
        XCTAssertEqual(store.outbox, ["call Helen", "and book the flights"])

        await database.setFailure(nil)
        await store.flush()

        XCTAssertEqual(store.turns.map(\.text), ["call Helen", "and book the flights"],
                       "both, in the order they were said")
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testTheQueueDrainsOnTheNextRead() async throws {
        let database = FailingDatabase(InMemoryRecordDatabase())
        let store = store(database)
        await database.setFailure(RecordDatabaseError.unavailable(underlying: CancellationError()))
        await store.send("call Helen")
        await database.setFailure(nil)

        let loop = Task { await store.refreshing(every: .milliseconds(10)) }
        defer { loop.cancel() }
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(store.turns.map(\.text), ["call Helen"],
                       "a send that failed on a bad minute goes with the next read")
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testRefreshingStopsWhenItsTaskIsCancelled() async throws {
        let database = InMemoryRecordDatabase()
        try await write(database, [(.person, "first")])
        let store = store(database)

        let loop = Task { await store.refreshing(every: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.turns.map(\.text), ["first"])
        loop.cancel()
        _ = await loop.value

        // A turn written after the loop stopped is not picked up: the loop
        // is the only thing reading.
        try await write(database, [(.assistant, "second")], device: DeviceID("hub"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.turns.map(\.text), ["first"])
    }

    func testRefreshingPicksUpTurnsWrittenWhileTheScreenIsOpen() async throws {
        let database = InMemoryRecordDatabase()
        try await write(database, [(.person, "first")])
        let store = store(database)
        let loop = Task { await store.refreshing(every: .milliseconds(10)) }
        defer { loop.cancel() }

        try await Task.sleep(for: .milliseconds(30))
        try await write(database, [(.assistant, "second")], device: DeviceID("hub"))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(Set(store.turns.map(\.text)), ["first", "second"])
    }

    func testAnUnsentTurnSurvivesARelaunch() async throws {
        // The app went away between the write and its acknowledgement. What
        // the person said is still owed an answer, so the next launch knows
        // about it.
        let database = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        await database.setFailAfterSave(true)
        await store(database, defaults: defaults).send("call Helen")

        let relaunched = store(database, defaults: defaults)

        XCTAssertEqual(relaunched.outbox, ["call Helen"])
    }

    func testARelaunchedRetryFindsTheCommittedTurnInsteadOfWritingASecond() async throws {
        // The marker TopoCore saves under the nonce is what makes the retry
        // exactly-once; keeping the nonce across the launch is what makes it
        // reachable at all.
        let database = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        await database.setFailAfterSave(true)
        await store(database, defaults: defaults).send("call Helen")
        await database.setFailAfterSave(false)

        let relaunched = store(database, defaults: defaults)
        await relaunched.flush()

        XCTAssertEqual(relaunched.turns.map(\.text), ["call Helen"], "one turn, not two")
        XCTAssertTrue(relaunched.outbox.isEmpty)
        XCTAssertNil(defaults.data(forKey: "topo.outbox"), "and nothing is still owed")
    }

    func testAFailedRefreshKeepsTheTurnsAlreadyRead() async throws {
        let database = FailingDatabase(InMemoryRecordDatabase())
        try await write(database.wrapped, [(.person, "first")])
        let store = store(database)
        await store.refresh()
        XCTAssertEqual(store.turns.map(\.text), ["first"])

        await database.setFailure(RecordDatabaseError.unavailable(underlying: CancellationError()))
        await store.refresh()

        XCTAssertEqual(store.turns.map(\.text), ["first"], "what the log last said is still what it said")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.notice, "Could not read just now. Showing the last read.")
    }

    func testAFailedFirstReadSaysWhy() async {
        let database = FailingDatabase(InMemoryRecordDatabase())
        await database.setFailure(RecordDatabaseError.rejected(underlying: CancellationError()))
        let store = store(database)
        await store.refresh()

        guard case .failed(let reason) = store.phase else { return XCTFail("the read should have failed") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(store.turns.isEmpty)
    }
}

/// An in-memory database that can be told to start failing, so a refresh
/// after a good read has something to fail on.
private actor FailingDatabase: RecordDatabase {
    let wrapped: InMemoryRecordDatabase
    private var failure: (any Error)?
    /// Commits the save and then throws, which is what a lost
    /// acknowledgement looks like from the writer's side.
    private var failAfterSave = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func setFailure(_ error: (any Error)?) { failure = error }

    func setFailAfterSave(_ on: Bool) { failAfterSave = on }

    func save(_ records: [Record]) async throws -> [Record] {
        if let failure { throw failure }
        let saved = try await wrapped.save(records)
        if failAfterSave { throw RecordDatabaseError.unavailable(underlying: CancellationError()) }
        return saved
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        if let failure { throw failure }
        return try await wrapped.fetch(ids)
    }

    func records(ofType type: String) async throws -> [Record] { try await query(RecordQuery(type: type)) }

    func query(_ query: RecordQuery) async throws -> [Record] {
        if let failure { throw failure }
        return try await wrapped.query(query)
    }
}

private actor Asked {
    private(set) var calls: [(String, TurnRef)] = []
    func note(_ endpoint: String, _ ref: TurnRef) { calls.append((endpoint, ref)) }
}

private struct AlwaysAlive: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}
