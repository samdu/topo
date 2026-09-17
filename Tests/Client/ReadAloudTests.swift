import TopoCore
import XCTest

@testable import Topo

/// Which landing reply the chat reads aloud: one continuing from a turn it sent from the microphone,
/// wherever that turn is among the reply's parents.
final class ReadAloudTests: XCTestCase {
    private func turn(_ device: String, _ sequence: Int64, _ role: TurnRole, _ text: String,
                      parents: [TurnRef] = [], nonce: String = UUID().uuidString) -> Turn {
        Turn(ref: TurnRef(device: DeviceID(device), sequence: sequence), parents: parents, role: role,
             text: text, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)), nonce: nonce)
    }

    func testTheReplyToASpokenTurnIsReadAloud() {
        let asked = turn("phone", 1, .person, "what is the capital of France", nonce: "spoken")
        let reply = turn("phone", 2, .assistant, "Paris.", parents: [asked.ref])
        XCTAssertEqual(ReadAloud.spokenTurn(answeredBy: reply, in: [asked, reply], spoken: ["spoken"]), "spoken")
    }

    /// `answerPending` over a fork: the reply's parents are the sorted heads, and a watch's turn
    /// sorts before the phone's, so the spoken turn is not the first parent.
    func testAReplyJoiningAForkIsReadAloudWhenTheSpokenTurnIsNotItsFirstParent() {
        let root = turn("phone", 1, .assistant, "hello")
        let spoken = turn("phone", 2, .person, "what is the capital of France", parents: [root.ref], nonce: "spoken")
        let limb = turn("aawatch", 1, .person, "remind me later", parents: [root.ref])
        let reply = turn("phone", 3, .assistant, "Paris. And I will.", parents: [limb.ref, spoken.ref])
        let turns = [root, spoken, limb, reply]
        let heads = Transcript(turns: [root, spoken, limb]).heads
        XCTAssertEqual(heads.count, 2, "the log was forked before the reply")
        XCTAssertEqual(heads.first, limb.ref, "the watch's turn sorts first, as in the reply's parents")
        XCTAssertEqual(ReadAloud.spokenTurn(answeredBy: reply, in: turns, spoken: ["spoken"]), "spoken")
    }

    func testATypedTurnsReplyIsNotReadAloud() {
        let asked = turn("phone", 1, .person, "typed", nonce: "typed")
        let reply = turn("phone", 2, .assistant, "answer", parents: [asked.ref])
        XCTAssertNil(ReadAloud.spokenTurn(answeredBy: reply, in: [asked, reply], spoken: ["other"]))
    }

    func testAPersonsTurnIsNeverReadAloud() {
        let asked = turn("phone", 1, .person, "spoken", nonce: "spoken")
        let echo = turn("phone", 2, .person, "again", parents: [asked.ref])
        XCTAssertNil(ReadAloud.spokenTurn(answeredBy: echo, in: [asked, echo], spoken: ["spoken"]))
    }
}
