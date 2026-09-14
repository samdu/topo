import TopoCore
import XCTest

@testable import Topo

/// What holding a turn offers. The gesture and the synthesis need a device; what this covers is
/// the offer itself — whose turns carry one, what it reads, and what it does with the text.
@MainActor
final class ReplayTests: XCTestCase {
    private func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [], role: role,
             text: text, at: Date())
    }

    /// Recorded calls, so a test can say what the offer did rather than what it read.
    private final class Calls {
        var said: [String] = []
        var stops = 0
    }

    private func replay(speaking: Bool = false, canSpeak: Bool = true) -> (Replay, Calls) {
        let calls = Calls()
        let replay = Replay(speaking: speaking, canSpeak: canSpeak,
                            say: { calls.said.append($0) }, stopSpeaking: { calls.stops += 1 })
        return (replay, calls)
    }

    func testToposOwnTurnIsOfferedAgain() {
        let (replay, _) = replay()
        XCTAssertEqual(replay.offer(for: turn(.assistant, "Hello."))?.title, "Say again")
    }

    func testThePersonsOwnTurnIsOfferedNothing() {
        let (replay, _) = replay()
        XCTAssertNil(replay.offer(for: turn(.person, "Hello.")),
                     "their words are not Topo's to say")
    }

    func testNothingIsOfferedWhileTheSceneIsNotActive() {
        let (replay, _) = replay(canSpeak: false)
        XCTAssertNil(replay.offer(for: turn(.assistant, "Hello.")),
                     "speaking is foreground work, so there is nothing to offer in the background")
    }

    func testTheOfferReadsStopWhileTheSpeakerIsSpeaking() {
        let (replay, calls) = replay(speaking: true)
        let offer = replay.offer(for: turn(.assistant, "Hello."))
        XCTAssertEqual(offer?.title, "Stop")
        offer?.act()
        XCTAssertEqual(calls.stops, 1)
        XCTAssertTrue(calls.said.isEmpty, "the offer while speaking stops rather than starts")
    }

    func testTakingTheOfferSaysThatTurnsText() {
        let (replay, calls) = replay()
        replay.offer(for: turn(.assistant, "One. Two."))?.act()
        XCTAssertEqual(calls.said, ["One. Two."])
        XCTAssertEqual(calls.stops, 0)
    }
}
