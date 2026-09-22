import TopoAuth
import TopoCore
import XCTest

@testable import Topo

/// The debug-only launch hooks. This bundle is itself a debug build, which is why it can see them.
final class DebugRunTests: XCTestCase {
    func testATokenInTheEnvironmentSignsTheAppIn() throws {
        let store = InMemoryTokenStore()
        let guest = InMemoryTokenStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DebugRun.signIn(store: store, guestStore: guest,
                                      environment: ["TOPO_CLAUDE_SETUP_TOKEN": "  sk-ant-oat01-test  ",
                                                    "TOPO_CLAUDE_SETUP_TOKEN_DAYS": "2"],
                                      now: now))
        let tokens = try XCTUnwrap(try store.load())
        XCTAssertEqual(tokens.accessToken, "sk-ant-oat01-test")
        // A setup token cannot be exchanged, so nothing is kept to exchange it with.
        XCTAssertTrue(tokens.refreshToken.isEmpty)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(tokens.isExpired(at: now))
        // A setup token is the long-lived kind, so the guest is handed the same one.
        XCTAssertEqual(try guest.load(), tokens)
    }

    func testWithoutOneNothingIsTouched() throws {
        let store = InMemoryTokenStore()
        let guest = InMemoryTokenStore()
        XCTAssertFalse(DebugRun.signIn(store: store, guestStore: guest, environment: [:]))
        XCTAssertFalse(DebugRun.signIn(store: store, guestStore: guest, environment: ["TOPO_CLAUDE_SETUP_TOKEN": "   "]))
        XCTAssertNil(try store.load())
        XCTAssertNil(try guest.load())
    }

    func testOnlyAnAskedForTurnIsSent() {
        XCTAssertNil(DebugRun.words([:]))
        XCTAssertNil(DebugRun.words(["TOPO_DEBUG_SEND": " \n "]))
        XCTAssertEqual(DebugRun.words(["TOPO_DEBUG_SEND": " what did I forget "]), "what did I forget")
    }

    // MARK: Which reply is this run's

    private func turn(_ device: String, _ sequence: Int64, _ role: TurnRole, _ text: String,
                      parents: [TurnRef] = [], nonce: String = UUID().uuidString) -> Turn {
        Turn(ref: TurnRef(device: DeviceID(device), sequence: sequence), parents: parents, role: role,
             text: text, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)), nonce: nonce)
    }

    func testAnOlderReplyIsNotTheAnswerToAPendingTurn() {
        let asked = turn("phone", 1, .person, "yesterday")
        let older = turn("phone", 2, .assistant, "an older answer", parents: [asked.ref])
        let pending = turn("phone", 3, .person, "today", parents: [older.ref], nonce: "this-run")
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [asked, older, pending]), .unanswered(pending))
        XCTAssertEqual(DebugRun.line(for: .unanswered(pending), nonce: "this-run", run: "R"),
                       "no reply to phone/3 in run R")
    }

    func testTheReplyIsTheOneToTheSubmittedTurnNotTheNewest() {
        let mine = turn("phone", 1, .person, "mine", nonce: "this-run")
        let reply = turn("phone", 2, .assistant, "to mine", parents: [mine.ref])
        let limb = turn("watch", 1, .person, "a limb's words", parents: [reply.ref])
        let later = turn("phone", 3, .assistant, "to the limb", parents: [limb.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [mine, reply, limb, later]), .answered(mine, reply: reply))
        XCTAssertEqual(DebugRun.line(for: .answered(mine, reply: reply), nonce: "this-run", run: "R"),
                       "reply to phone/1 in run R: to mine")
    }

    func testAReplyJoiningSeveralHeadsAnswersEachOfThem() {
        let other = turn("watch", 1, .person, "from the watch")
        let mine = turn("phone", 1, .person, "mine", nonce: "this-run")
        let joined = turn("phone", 2, .assistant, "to both", parents: [mine.ref, other.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [other, mine, joined]), .answered(mine, reply: joined))
    }

    func testATurnThatNeverReachedTheLogHasNoAnswer() {
        let asked = turn("phone", 1, .person, "someone else's", nonce: "another-run")
        let reply = turn("phone", 2, .assistant, "to them", parents: [asked.ref])
        XCTAssertEqual(DebugRun.answer(to: "this-run", in: [asked, reply]), .notInLog)
        // A nonce is never empty on a turn this run sent; an empty one names no turn at all.
        XCTAssertEqual(DebugRun.answer(to: "", in: [turn("phone", 3, .person, "old", nonce: "")]), .notInLog)
    }
}
