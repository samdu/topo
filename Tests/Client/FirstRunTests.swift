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

    /// The question is answered when it stops being asked over a log still read that has a turn
    /// or words on the line. A read taken away (a device taking primary back), a turn in flight
    /// with nothing on the line (a demotion's save holds the harness busy), and a question never
    /// asked are not answers.
    func testTheQuestionIsAnsweredOnlyByATurn() {
        XCTAssertTrue(FirstRun.answered(asked: true, read: true, empty: true, waiting: true))
        XCTAssertTrue(FirstRun.answered(asked: true, read: true, empty: false, waiting: false))
        XCTAssertFalse(FirstRun.answered(asked: true, read: true, empty: true, waiting: false),
                       "the harness going busy with nothing on the line answered the question")
        XCTAssertFalse(FirstRun.answered(asked: true, read: false, empty: true, waiting: true), "a read taken away answered the question")
        XCTAssertFalse(FirstRun.answered(asked: false, read: true, empty: false, waiting: true), "a question never asked was answered")
    }

    /// Topo holds the question up while it is asked, and nothing otherwise: whatever he was
    /// drawn as stays, sign and all.
    func testTopoHoldsTheQuestionWhileItIsAsked() {
        let state = MascotState(model: "sonnet")
        XCTAssertEqual(FirstRun.drawn(state, asks: true).sign, FirstRun.question)
        XCTAssertEqual(FirstRun.drawn(state, asks: true).input.activity, "sign")
        XCTAssertEqual(FirstRun.drawn(state, asks: false), state)
    }

    /// A thumb on the microphone takes Topo away with the flanks, but not while he holds the
    /// question: holding the microphone is how it is answered, and it stands until it is.
    func testTheQuestionStaysUpWhileTheMicrophoneIsHeld() {
        let held = Look().composer.flank.heldOpacity
        XCTAssertEqual(FirstRun.opacity(holding: true, asks: true, held: held), 1)
        XCTAssertEqual(FirstRun.opacity(holding: true, asks: false, held: held), held)
        XCTAssertEqual(FirstRun.opacity(holding: false, asks: true, held: held), 1)
        XCTAssertEqual(FirstRun.opacity(holding: false, asks: false, held: held), 1)
    }

    /// Under Reduce Motion he is one still, and a still handed a sign holds it up: the question
    /// is on the screen whether or not he moves.
    @MainActor
    func testTheReduceMotionStillHoldsTheSign() throws {
        func drawn(sign: String?) throws -> CGRect {
            let driver = MascotDriver()
            driver.input = FirstRun.drawn(MascotState(model: "sonnet"), asks: sign != nil).input
            driver.conditions = .init(active: true, onScreen: true, reduceMotion: true)
            let image = try XCTUnwrap(driver.image, "no still was drawn")
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            var x1 = -1
            for y in 0..<image.height { for x in 0..<image.width where data[(y * image.width + x) * 4 + 3] != 0 { x1 = max(x1, x) } }
            return CGRect(x: 0, y: 0, width: x1 + 1, height: 1)
        }
        XCTAssertGreaterThan(try drawn(sign: FirstRun.question).maxX, MascotSprite.reach.maxX,
                             "the still dropped the sign")
        XCTAssertLessThanOrEqual(try drawn(sign: nil).maxX, MascotSprite.reach.maxX)
    }

    func testThePlaceholderStandsOnlyOverAnUnreadEmptyPage() {
        XCTAssertTrue(ReadingLog.stands(read: false, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: false, drawn: true))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: true))
    }
}
