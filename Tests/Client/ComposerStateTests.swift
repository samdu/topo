import XCTest

@testable import Topo

/// What the glass draws for a microphone, read off the mapping rather than off the view. The
/// chat screen hands over four facts from `VoiceInput` and the composer decides which of the
/// four states they are; that decision is worth pinning because three of the four are states a
/// simulator will not hold still long enough to photograph.
@MainActor
final class ComposerStateTests: XCTestCase {
    private func state(canListen: Bool = true, listening: Bool = false,
                       owner: VoiceInput.Gate? = nil, handsFree: Bool = false) -> Composer.MicState {
        Composer.MicState(canListen: canListen, listening: listening, owner: owner,
                          handsFree: handsFree)
    }

    func testNothingOpenIsIdle() {
        let mic = state()
        XCTAssertEqual(mic.appearance, .idle)
        XCTAssertFalse(mic.open, "a shut microphone leaves the glass clear")
        XCTAssertFalse(mic.holding)
    }

    func testTheChatsOwnOpenSessionIsHeld() {
        let mic = state(listening: true, owner: .chat)
        XCTAssertEqual(mic.appearance, .held)
        XCTAssertTrue(mic.open, "the glass takes the colour while the microphone is open")
        XCTAssertTrue(mic.holding, "the thumb is on the glass, so the flanks go")
    }

    /// The first run has a microphone of its own and this glass is not it. Two surfaces never
    /// hold the microphone at once, and a session that is not this one's does not light it.
    func testAnotherSurfacesSessionLeavesTheGlassAlone() {
        let mic = state(listening: true, owner: .firstRun)
        XCTAssertEqual(mic.appearance, .idle)
        XCTAssertFalse(mic.open)
    }

    /// A tap leaves the microphone open with the hand off the glass, so the flanks stay and the
    /// mark becomes the waveform.
    func testATapLeavesItHandsFree() {
        let mic = state(listening: true, owner: .chat, handsFree: true)
        XCTAssertEqual(mic.appearance, .handsFree)
        XCTAssertTrue(mic.open)
        XCTAssertFalse(mic.holding, "hands free is not a thumb on the glass")
    }

    /// A press that would be refused reads as refused whatever else is true of the session: the
    /// jewel is drained and faded, and the diagnostics `speech` row is what says why.
    func testAPressThatWouldBeRefusedIsDimmedAboveEverythingElse() {
        XCTAssertEqual(state(canListen: false).appearance, .dimmed)
        XCTAssertEqual(state(canListen: false, listening: true, owner: .chat).appearance, .dimmed)
        XCTAssertEqual(state(canListen: false, listening: true, owner: .chat, handsFree: true).appearance,
                       .dimmed)
    }

    /// The three labels are the only route the two UI suites have to this button, and they are
    /// read off `listening` and `handsFree` alone — as the chat screen read them before the
    /// composer existed, with no owner in the question.
    func testTheLabelsAreTheThreeTheSuitesLookFor() {
        XCTAssertEqual(state().label, "Hold to talk")
        XCTAssertEqual(state(canListen: false).label, "Hold to talk")
        XCTAssertEqual(state(listening: true, owner: .chat).label, "Listening; release to send")
        XCTAssertEqual(state(listening: true, owner: .firstRun).label, "Listening; release to send")
        XCTAssertEqual(state(listening: true, owner: .chat, handsFree: true).label,
                       "Listening; press to send")
        XCTAssertEqual(state(handsFree: true).label, "Listening; press to send")
    }
}
