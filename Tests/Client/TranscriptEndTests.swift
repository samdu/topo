import TopoCore
import XCTest

@testable import Topo

/// Where the transcript scrolls to with work rows drawn: the row under the newest person's turn,
/// under a turn on its way and under the row's own words, while nothing is drawn below it; and
/// the row's work drawn once, under the log's turn once the log has it.
@MainActor
final class TranscriptEndTests: XCTestCase {
    private let step = [WorkStep(id: "s", kind: .thought(text: nil))]

    func testTheNewestPersonsTurnWithWorkEndsAtItsWork() throws {
        let person = try XCTUnwrap(PreviewTurns.fitting.last)
        let view = TranscriptView(turns: PreviewTurns.fitting, work: [person.nonce: step])
        XCTAssertEqual(view.end, AnyHashable(TranscriptView.workID(person.nonce)))
        XCTAssertEqual(TranscriptView(turns: PreviewTurns.fitting).end, AnyHashable(person.ref), "no work, the turn")
    }

    func testAnAnswerUnderTheWorkIsTheEnd() throws {
        let answer = try XCTUnwrap(PreviewTurns.short.last)
        let view = TranscriptView(turns: PreviewTurns.fitting, answer: answer, work: ["row": step], rowNonce: "row")
        XCTAssertEqual(view.end, AnyHashable(answer.ref))
    }

    func testTheRowsWorkComesBeforeTheDraftAndIsDrawnOnce() throws {
        let row = TranscriptView(turns: PreviewTurns.short, work: ["row": step], rowNonce: "row")
        XCTAssertEqual(row.rowWork, "row")
        XCTAssertEqual(row.end, AnyHashable(TranscriptView.workID("row")))

        let landed = try XCTUnwrap(PreviewTurns.fitting.last)
        let view = TranscriptView(turns: PreviewTurns.fitting, work: [landed.nonce: step], rowNonce: landed.nonce)
        XCTAssertNil(view.rowWork, "the log's turn draws its work; the row draws it no more")
    }

    func testAQueuedTurnWithWorkAndNoReplyEndsAtItsWork() {
        let view = TranscriptView(turns: PreviewTurns.short, queued: ([], [QueuedTurn(text: "and", nonce: "q")]),
                                  work: ["q": step])
        XCTAssertEqual(view.end, AnyHashable(TranscriptView.workID("q")))
    }
}
