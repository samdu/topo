import CloudKit
import UIKit
import XCTest

final class BoardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func revision(_ ref: String, card: String, body: String, state: CardState = .posted,
                          parents: [String] = [], owner: String = "phone", at: TimeInterval = 0) -> CardRevision {
        return CardRevision(ref: ref, card: card, owner: owner, body: body, state: state,
                            parents: parents, at: t0 + at)
    }

    func testACardIsTheNewestThingSaidAboutIt() {
        let board = Board(revisions: [
            revision("phone/1", card: "phone/1", body: "milk", at: 0),
            revision("hub/1", card: "phone/1", body: "milk", state: .ticked, parents: ["phone/1"], at: 60),
        ])
        XCTAssertEqual(board.cards.count, 1)
        XCTAssertEqual(board.cards.first?.state, .ticked)
        XCTAssertEqual(board.cards.first?.owner, "phone")
        XCTAssertTrue(board.open.isEmpty)
    }

    func testTwoDevicesChangingOneCardConverge() {
        // Both continue from the posting without seeing each other.
        let board = Board(revisions: [
            revision("phone/1", card: "phone/1", body: "bins", at: 0),
            revision("phone/2", card: "phone/1", body: "bins", state: .ticked, parents: ["phone/1"], at: 10),
            revision("hub/1", card: "phone/1", body: "bins", state: .dismissed, parents: ["phone/1"], at: 20),
        ])
        XCTAssertEqual(board.cards.count, 1)
        XCTAssertEqual(board.cards.first?.state, .dismissed)
    }

    func testTheBoardIsNewestPostingFirstAndTickingDoesNotMoveIt() {
        let board = Board(revisions: [
            revision("phone/1", card: "phone/1", body: "first", at: 0),
            revision("phone/2", card: "phone/2", body: "second", at: 60),
            revision("phone/3", card: "phone/1", body: "first", state: .posted, parents: ["phone/1"], at: 600),
        ])
        XCTAssertEqual(board.cards.map { $0.body }, ["second", "first"])
    }

    func testOnlyOpenCardsAreOnTheWall() {
        let board = Board(revisions: [
            revision("phone/1", card: "phone/1", body: "open", at: 0),
            revision("phone/2", card: "phone/2", body: "done", at: 10),
            revision("phone/3", card: "phone/2", body: "done", state: .ticked, parents: ["phone/2"], at: 20),
        ])
        XCTAssertEqual(board.open.map { $0.body }, ["open"])
        XCTAssertEqual(board.cards.count, 2)
    }

    func testARevisionReadsFromItsRecord() {
        let record = CKRecord(recordType: "Card", recordID: CKRecord.ID(recordName: "card/phone/1"))
        record["card"] = "phone/1" as NSString
        record["owner"] = "phone" as NSString
        record["body"] = "milk" as NSString
        record["state"] = "posted" as NSString
        record["at"] = t0 as NSDate
        record["parents"] = [] as NSArray
        let revision = CardRevision(record: record)
        XCTAssertEqual(revision?.ref, "phone/1")
        XCTAssertEqual(revision?.body, "milk")
        XCTAssertEqual(revision?.state, .posted)
    }

    func testARecordThatIsNotACardIsNotOne() {
        let wrongType = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: "card/phone/1"))
        XCTAssertNil(CardRevision(record: wrongType))

        let noState = CKRecord(recordType: "Card", recordID: CKRecord.ID(recordName: "card/phone/1"))
        noState["card"] = "phone/1" as NSString
        noState["owner"] = "phone" as NSString
        noState["body"] = "milk" as NSString
        noState["at"] = t0 as NSDate
        XCTAssertNil(CardRevision(record: noState))

        let notNamedAsOne = CKRecord(recordType: "Card", recordID: CKRecord.ID(recordName: "scribble"))
        notNamedAsOne["card"] = "phone/1" as NSString
        notNamedAsOne["owner"] = "phone" as NSString
        notNamedAsOne["body"] = "milk" as NSString
        notNamedAsOne["state"] = "posted" as NSString
        notNamedAsOne["at"] = t0 as NSDate
        XCTAssertNil(CardRevision(record: notNamedAsOne))
    }
}

/// A source with a scripted answer, so the screen can be tested with no
/// account and no network.
final class StubBoardSource: BoardSource {
    private let result: Result<Board, TranscriptError>
    private(set) var reads = 0

    init(_ result: Result<Board, TranscriptError>) { self.result = result }

    func read(_ completion: @escaping (Result<Board, TranscriptError>) -> Void) {
        reads += 1
        completion(result)
    }
}

/// The transcript's own stub is private to its tests, and this needs one
/// too: a screen that reads nothing, so the layout is what is under test.
private final class QuietTranscriptSource: TranscriptSource {
    func read(completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        completion(.success(Transcript(turns: [])))
    }
}

final class HouseLayoutTests: XCTestCase {
    private func house() -> HouseViewController {
        let transcript = TranscriptViewController(source: QuietTranscriptSource())
        let board = BoardViewController(source: StubBoardSource(.success(Board(revisions: []))))
        let house = HouseViewController(transcript: transcript, board: board)
        house.loadViewIfNeeded()
        return house
    }

    func testAWideScreenPutsThemSideBySideWithTheTranscriptFirst() {
        let house = self.house()
        house.arrange(for: CGSize(width: 1024, height: 768))
        XCTAssertEqual(house.layoutAxis, .horizontal)
        XCTAssertTrue(house.layoutOrder.first is TranscriptViewController)
    }

    func testATallScreenStacksThemWithTheBoardAtEyeHeight() {
        let house = self.house()
        house.arrange(for: CGSize(width: 768, height: 1024))
        XCTAssertEqual(house.layoutAxis, .vertical)
        XCTAssertTrue(house.layoutOrder.first is BoardViewController)
    }

    func testTurningTheDeviceRearrangesThem() {
        let house = self.house()
        house.arrange(for: CGSize(width: 768, height: 1024))
        house.arrange(for: CGSize(width: 1024, height: 768))
        XCTAssertEqual(house.layoutAxis, .horizontal)
        XCTAssertEqual(house.layoutOrder.count, 2)
        house.arrange(for: CGSize(width: 768, height: 1024))
        XCTAssertEqual(house.layoutAxis, .vertical)
        XCTAssertEqual(house.layoutOrder.count, 2)
    }
}

/// A store with scripted answers, so the reader can be tested with no
/// account and no network.
private final class StubCardStore: CardRecordStore {
    var queryResult: Result<[CKRecord], TranscriptError>
    var fetchResult: Result<[CKRecord], TranscriptError>
    /// Records the query pretends not to know about yet, by name.
    var hidden: [String: CKRecord] = [:]
    private(set) var fetchedNames: [[String]] = []

    init(query: Result<[CKRecord], TranscriptError>, fetch: Result<[CKRecord], TranscriptError> = .success([])) {
        self.queryResult = query
        self.fetchResult = fetch
    }

    func allCards(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        completion(queryResult)
    }

    func fetchCards(named names: [String], _ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        fetchedNames.append(names)
        if case .failure = fetchResult { return completion(fetchResult) }
        completion(.success(names.compactMap { hidden[$0] }))
    }
}

private func cardRecord(_ ref: String, card: String, body: String, state: String = "posted",
                        parents: [String] = [], owner: String = "phone", at: Date) -> CKRecord {
    let record = CKRecord(recordType: "Card", recordID: CKRecord.ID(recordName: "card/" + ref))
    record["card"] = card as NSString
    record["owner"] = owner as NSString
    record["body"] = body as NSString
    record["state"] = state as NSString
    record["parents"] = parents as NSArray
    record["at"] = at as NSDate
    record["sequence"] = (BoardReader.split(ref)?.1 ?? 0) as NSNumber
    return record
}

final class BoardReaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func read(_ store: CardRecordStore) -> Result<Board, TranscriptError> {
        let reader = BoardReader(store: store)
        var answer: Result<Board, TranscriptError>?
        let done = expectation(description: "read")
        reader.read { result in
            answer = result
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return answer!
    }

    func testATickTheQueryHasNotCaughtUpWithIsStillFound() {
        // The board as the index knows it: a card, still open.
        let store = StubCardStore(query: .success([
            cardRecord("phone/1", card: "phone/1", body: "bins", at: t0),
        ]))
        // And the tick, which it has not caught up with.
        store.hidden["card/phone/2"] = cardRecord("phone/2", card: "phone/1", body: "bins",
                                                  state: "ticked", parents: ["phone/1"], at: t0 + 60)

        guard case .success(let board) = read(store) else { return XCTFail("not a board") }
        // Without the probe this card would still be on the wall.
        XCTAssertTrue(board.open.isEmpty)
        XCTAssertEqual(board.cards.first?.state, .ticked)
        XCTAssertEqual(store.fetchedNames.first, ["card/phone/2"])
    }

    func testAProbeThatFailsIsAReadThatFailed() {
        let store = StubCardStore(query: .success([
            cardRecord("phone/1", card: "phone/1", body: "bins", at: t0),
        ]), fetch: .failure(.unavailable(NSError(domain: "test", code: 1))))
        guard case .failure = read(store) else {
            return XCTFail("a stale board is not an answer")
        }
    }

    func testAQueryThatFailsIsAReadThatFailed() {
        let store = StubCardStore(query: .failure(.unavailable(NSError(domain: "test", code: 1))))
        guard case .failure = read(store) else { return XCTFail("not a failure") }
    }

    func testAnEmptyBoardIsAnAnswerAndNotAFailure() {
        guard case .success(let board) = read(StubCardStore(query: .success([]))) else {
            return XCTFail("not a board")
        }
        XCTAssertTrue(board.isEmpty)
    }

    func testTheProbeStopsWhenThereIsNothingPastTheEnd() {
        let store = StubCardStore(query: .success([
            cardRecord("phone/1", card: "phone/1", body: "bins", at: t0),
        ]))
        _ = read(store)
        XCTAssertEqual(store.fetchedNames.count, 1)
    }
}
