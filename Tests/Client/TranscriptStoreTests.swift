import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private let device = DeviceID("watch-test")

    private func store(_ database: any RecordDatabase,
                       ensureZone: @escaping @Sendable () async throws -> Void = {}) -> TranscriptStore {
        TranscriptStore(database: database, device: device, ensureZone: ensureZone)
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

    func testAFailedZoneCreationIsSaidAndNothingIsWritten() async {
        let database = InMemoryRecordDatabase()
        let store = store(database, ensureZone: { throw RecordDatabaseError.unavailable(underlying: CancellationError()) })

        await store.send("hello")

        XCTAssertTrue(store.turns.isEmpty)
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

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func setFailure(_ error: (any Error)?) { failure = error }

    func save(_ records: [Record]) async throws -> [Record] {
        if let failure { throw failure }
        return try await wrapped.save(records)
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        if let failure { throw failure }
        return try await wrapped.fetch(ids)
    }

    func query(_ query: RecordQuery) async throws -> [Record] {
        if let failure { throw failure }
        return try await wrapped.query(query)
    }
}
