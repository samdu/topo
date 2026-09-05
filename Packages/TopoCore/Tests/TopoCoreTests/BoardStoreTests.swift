import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct BoardStoreTests {
    let db = InMemoryRecordDatabase()
    var store: BoardStore { BoardStore(database: db) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aPostedCardIsOnTheBoardAndSaysWhoseItIs() async throws {
        let w = try await store.writer(for: phone)
        let posted = try await w.post("milk", at: t0)
        #expect(posted.ref == CardRef(device: phone, sequence: 1))
        #expect(CardRevision.recordID(for: posted.ref).name == "card/phone/1")

        let board = try await store.read()
        let card = try #require(board.cards.first)
        #expect(card.body == "milk")
        #expect(card.owner == phone)
        #expect(card.state == .posted)
        #expect(card.isOpen)
        #expect(board.open.count == 1)
    }

    @Test func anyoneInTheHouseMayTickAndTheCardKeepsItsOwner() async throws {
        let mine = try await store.writer(for: phone)
        let theirs = try await store.writer(for: hub)
        let posted = try await mine.post("bins", at: t0)

        try await theirs.tick(posted.card, on: store.read(), at: t0 + 60)
        let board = try await store.read()
        let card = try #require(board[posted.card])
        #expect(card.state == .ticked)
        #expect(card.owner == phone)
        #expect(!card.isOpen)
        #expect(board.open.isEmpty)
        // The tick is a revision of its own; nothing was overwritten.
        #expect(board.revisions.count == 2)
    }

    @Test func dismissingAndRepostingAreJustRevisions() async throws {
        let w = try await store.writer(for: phone)
        let posted = try await w.post("call the plumber", at: t0)
        try await w.dismiss(posted.card, on: store.read(), at: t0 + 1)
        #expect(try await store.read()[posted.card]?.state == .dismissed)
        try await w.repost(posted.card, on: store.read(), at: t0 + 2)
        let board = try await store.read()
        #expect(board[posted.card]?.state == .posted)
        #expect(board.revisions.count == 3)
        // What it says has not changed, only where it has got to.
        #expect(board[posted.card]?.body == "call the plumber")
    }

    @Test func amendingKeepsWhereTheCardHasGotTo() async throws {
        let w = try await store.writer(for: phone)
        let posted = try await w.post("milk", at: t0)
        try await w.tick(posted.card, on: store.read(), at: t0 + 1)
        try await w.amend(posted.card, to: "oat milk", on: store.read(), at: t0 + 2)
        let card = try #require(try await store.read()[posted.card])
        #expect(card.body == "oat milk")
        #expect(card.state == .ticked)
    }

    @Test func twoDevicesChangingOneCardSettleOnTheNewer() async throws {
        let mine = try await store.writer(for: phone)
        let theirs = try await store.writer(for: hub)
        let posted = try await mine.post("bins", at: t0)
        let seen = try await store.read()

        // Neither saw the other: both continue from the posting.
        try await mine.tick(posted.card, on: seen, at: t0 + 10)
        try await theirs.dismiss(posted.card, on: seen, at: t0 + 20)

        let board = try await store.read()
        // A board converges rather than forking: the house sees one card.
        #expect(board.cards.count == 1)
        #expect(board[posted.card]?.state == .dismissed)
        #expect(board.heads(of: posted.card).count == 2)
        // The one that lost is still in the log, unharmed.
        #expect(board.revisions.count == 3)
        #expect(board.revisions.values.contains { $0.state == .ticked })
    }

    @Test func aChangeThatSawTheForkResolvesIt() async throws {
        let mine = try await store.writer(for: phone)
        let theirs = try await store.writer(for: hub)
        let posted = try await mine.post("bins", at: t0)
        let seen = try await store.read()
        try await mine.tick(posted.card, on: seen, at: t0 + 10)
        try await theirs.dismiss(posted.card, on: seen, at: t0 + 20)

        let forked = try await store.read()
        #expect(forked.heads(of: posted.card).count == 2)
        try await mine.repost(posted.card, on: forked, at: t0 + 30)
        let board = try await store.read()
        #expect(board.heads(of: posted.card).count == 1)
        #expect(board[posted.card]?.state == .posted)
    }

    @Test func theBoardIsNewestPostingFirst() async throws {
        let w = try await store.writer(for: phone)
        try await w.post("first", at: t0)
        try await w.post("second", at: t0 + 60)
        try await w.post("third", at: t0 + 120)
        let board = try await store.read()
        #expect(board.cards.map(\.body) == ["third", "second", "first"])
        // Ticking does not move a card up the board.
        let oldest = try #require(board.cards.last)
        try await w.tick(oldest.id, on: board, at: t0 + 200)
        #expect(try await store.read().cards.map(\.body) == ["third", "second", "first"])
    }

    @Test func nothingIsWrittenFromAnIncompleteBoard() async throws {
        let w = try await store.writer(for: phone)
        let posted = try await w.post("milk", at: t0)
        try await w.post("bread", at: t0 + 1)

        let stale = BoardStore(database: StaleTailDatabase(inner: db))
        let board = try await stale.read()
        #expect(!board.isComplete)
        await #expect(throws: BoardError.self) {
            try await w.tick(posted.card, on: board, at: t0 + 2)
        }
    }

    @Test func aChangeToACardNobodyPostedIsRefused() async throws {
        let w = try await store.writer(for: phone)
        await #expect(throws: BoardError.self) {
            try await w.tick(CardID("phone/99"), on: store.read(), at: t0)
        }
    }

    @Test func aLostAcknowledgementRetriedWithTheSameNonceWritesOneRevision() async throws {
        let flaky = FlakyOnceDatabase(inner: db)
        let store = BoardStore(database: flaky)
        let w = try await store.writer(for: phone)
        await #expect(throws: RecordDatabaseError.self) {
            try await w.post("milk", at: t0, nonce: "n1")
        }
        let again = try await w.post("milk", at: t0, nonce: "n1")
        #expect(again.ref == CardRef(device: phone, sequence: 1))
        let board = try await store.read()
        #expect(board.cards.count == 1)
        #expect(board.revisions.count == 1)
    }

    @Test func aRevisionRoundTripsThroughItsRecord() async throws {
        let w = try await store.writer(for: phone)
        let posted = try await w.post("milk", at: t0)
        let record = try #require(await db.current(CardRevision.recordID(for: posted.ref)))
        #expect(CardRevision(record: record) == posted)
        #expect(CardRevision(record: Record(type: CardRevision.recordType, id: RecordID("card/phone/9"))) == nil)
    }

    @Test func aRevisionTheQueryHasNotCaughtUpWithIsReportedMissing() async throws {
        let w = try await store.writer(for: phone)
        try await w.post("milk", at: t0)
        try await w.post("bread", at: t0 + 1)
        let stale = BoardStore(database: StaleTailDatabase(inner: db))
        let board = try await stale.read()
        #expect(board.missing == [CardRef(device: phone, sequence: 2)])
        #expect(!board.isComplete)
    }

    @Test func noReadAsksForEverything() async throws {
        let watcher = QueryWatcher(inner: db)
        let store = BoardStore(database: watcher)
        let w = try await store.writer(for: phone)
        try await w.post("milk", at: t0)
        _ = try await store.read()
        let asked = await watcher.queries
        #expect(!asked.isEmpty)
        #expect(asked.allSatisfy { !$0.filters.isEmpty })
    }
}
