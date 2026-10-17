import XCTest

@testable import Topo

/// When the first-run question is asked (`FirstRun.asks`) and when the placeholder stands in the
/// transcript's place (`ReadingLog.stands`). The harness's side of both — a read that failed, the
/// answer on the line — is `HarnessIntegrationTests`'.
final class FirstRunTests: XCTestCase {
    /// Of every combination, the question is asked in one: the log read, empty, nothing on the
    /// line or in flight, the person's hand not on the chat, not answered, no fixture drawn.
    func testTheQuestionIsAskedOnlyOverAReadEmptyLogWithNothingGoing() {
        var asked: [[Bool]] = []
        let both = [false, true]
        for read in both { for empty in both { for waiting in both { for busy in both {
            for engaged in both { for answered in both { for fixture in both {
                if FirstRun.asks(read: read, empty: empty, waiting: waiting, busy: busy, engaged: engaged,
                                 answered: answered, fixture: fixture) {
                    asked.append([read, empty, waiting, busy, engaged, answered, fixture])
                }
            } } }
        } } } }
        XCTAssertEqual(asked, [[true, true, false, false, false, false, false]])
    }

    /// The composer works while the log is unread, so the first read of an empty log can return
    /// with the chat's microphone open, its field focused or words in its row. The question
    /// waits for each to end; one that ended in a turn left words on the line, and it is not asked.
    func testTheQuestionWaitsForTheChatsMicrophoneAndField() {
        func asks(engaged: Bool, waiting: Bool = false) -> Bool {
            FirstRun.asks(read: true, empty: true, waiting: waiting, busy: false, engaged: engaged, answered: false)
        }
        XCTAssertFalse(asks(engaged: true), "the question arrived over the chat's own session")
        XCTAssertTrue(asks(engaged: false), "a session that ended in nothing left the question unasked")
        XCTAssertFalse(asks(engaged: false, waiting: true), "asked over the turn the session ended in")
    }

    /// Words said before the read are drawn as any turn on its way is, and the placeholder never
    /// stands over them; once the log is read it does not stand at all.
    /// The question stands while it is asked, and while its own microphone's answer is still
    /// being heard though a turn the log brought has ended the asking.
    func testTheQuestionStandsUntilItsOwnAnswerIsHeard() {
        XCTAssertTrue(FirstRun.stands(hearing: false, asks: true))
        XCTAssertTrue(FirstRun.stands(hearing: true, asks: false), "a turn from another device took the question from under an answer being heard")
        XCTAssertTrue(FirstRun.stands(hearing: true, asks: true))
        XCTAssertFalse(FirstRun.stands(hearing: false, asks: false))
    }

    func testThePlaceholderStandsOnlyOverAnUnreadEmptyPage() {
        XCTAssertTrue(ReadingLog.stands(read: false, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: false, drawn: true))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: false))
        XCTAssertFalse(ReadingLog.stands(read: true, drawn: true))
    }
}
