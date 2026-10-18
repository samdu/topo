import TopoMascot
import XCTest

@testable import Topo

/// When the first-run question is asked (`FirstRun.asks`) and when the placeholder stands in the
/// transcript's place (`ReadingLog.stands`). The harness's side of both — a read that failed, the
/// answer on the line — is `HarnessIntegrationTests`'.
final class FirstRunTests: XCTestCase {
    /// Of every combination, the question is asked in one: the log read, empty, nothing on the
    /// line or in flight, not answered, no fixture drawn.
    func testTheQuestionIsAskedOnlyOverAReadEmptyLogWithNothingGoing() {
        var asked: [[Bool]] = []
        let both = [false, true]
        for read in both { for empty in both { for waiting in both { for busy in both {
            for answered in both { for fixture in both {
                if FirstRun.asks(read: read, empty: empty, waiting: waiting, busy: busy,
                                 answered: answered, fixture: fixture) {
                    asked.append([read, empty, waiting, busy, answered, fixture])
                }
            } }
        } } } }
        XCTAssertEqual(asked, [[true, true, false, false, false, false]])
    }

    /// The question is answered when it stops being asked over a log still read: the person's
    /// turn reached the line or the log. A read taken away (a device taking primary back) is not
    /// an answer, and neither is a question that was never asked.
    func testTheQuestionIsAnsweredOnlyWhenItGoesOverARead() {
        XCTAssertTrue(FirstRun.answered(asked: true, asks: false, read: true))
        XCTAssertFalse(FirstRun.answered(asked: true, asks: false, read: false), "a read taken away answered the question")
        XCTAssertFalse(FirstRun.answered(asked: false, asks: false, read: true), "a question never asked was answered")
        XCTAssertFalse(FirstRun.answered(asked: true, asks: true, read: true))
    }

    /// Topo holds the question up while it is asked, and nothing otherwise: whatever he was
    /// drawn as stays, sign and all.
    func testTopoHoldsTheQuestionWhileItIsAsked() {
        let state = MascotState(model: "sonnet")
        XCTAssertEqual(FirstRun.drawn(state, asks: true).sign, FirstRun.question)
        XCTAssertEqual(FirstRun.drawn(state, asks: true).input.activity, "sign")
        XCTAssertEqual(FirstRun.drawn(state, asks: false), state)
    }

    /// The question's sign reaches past every other pose, and what the engine draws taking it up
    /// and holding it is inside that reach in both facings, so the roam keeps the whole board on
    /// the screen and off the glass.
    @MainActor
    func testTheQuestionsSignIsDrawnInsideItsReach() {
        let reach = MascotSprite.reach(sign: FirstRun.question)
        XCTAssertTrue(reach.contains(MascotSprite.reach), "the sign's reach \(reach) is smaller than a pose's")
        XCTAssertGreaterThan(reach.width, MascotSprite.reach.width, "the sign reaches no further than a pose")
        XCTAssertEqual(reach.midX, MascotSprite.box.midX, accuracy: 0.5, "the reach is not symmetric about his axis")
        XCTAssertEqual(MascotSprite.reach(sign: nil), MascotSprite.reach)
        var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
        for facing in MascotFacing.allCases {
            let engine = Topo(random: { 0.5 })
            for _ in 0..<(MascotSprite.signSettle * 30) {
                engine.update(1.0 / 30, TopoInput(activity: "sign", sign: FirstRun.question, facing: facing.rawValue))
            }
            engine.draw(&rgba)
            var outside = 0, drawn = 0
            for y in 0..<Topo.height { for x in 0..<Topo.width where rgba[(y * Topo.width + x) * 4 + 3] != 0 {
                drawn += 1
                if !reach.contains(CGPoint(x: x, y: y)) { outside += 1 }
            } }
            XCTAssertGreaterThan(drawn, 0, "\(facing) drew nothing")
            XCTAssertEqual(outside, 0, "\(facing) drew \(outside) pixels outside \(reach)")
        }
    }

    func testThePlaceholderStandsOnlyOverAnUnreadEmptyPage() {
        XCTAssertTrue(ReadingLog.stands(read: false, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: false, drawn: true))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: true))
    }
}
