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
