import TopoCore
import TopoUserland
import XCTest

@testable import Topo

/// The work row's steps as the guest's events make them: under the nonce of the turn they
/// answer, a result landing on its own call, and nothing kept past a login.
@MainActor
final class TurnWorkTests: XCTestCase {
    private func run(_ work: TurnWork, heard nonce: String, _ events: [StreamEvent]) {
        work.follow(.began(pid: 1, answering: [], heard: nonce))
        for event in events { work.follow(.update(.event(event))) }
    }

    func testAGuestTurnsStepsLandUnderTheTurnTheyAnswer() {
        let work = TurnWork()
        run(work, heard: "n1", [
            .thinking, .thought("weigh it"),
            .toolUse(name: "Bash", id: "t1"),
            .toolInput(id: "t1", name: "Bash", summary: "Fetch it", input: "command: curl x"),
        ])
        XCTAssertEqual(work.live, "n1")
        XCTAssertEqual(work.steps["n1"]?.map(\.kind), [
            .thought(text: "weigh it"), .call(name: "Bash", summary: "Fetch it", input: "command: curl x"),
        ])
        XCTAssertNil(work.steps["n1"]?.last?.outcome, "a call still running has no outcome")

        // a sub-agent's result names a call the row does not have, and changes nothing
        work.follow(.update(.event(.toolResult(isError: false, text: "sub", id: "t9"))))
        work.follow(.update(.event(.toolResult(isError: true, text: "boom", id: "t1"))))
        XCTAssertEqual(work.steps["n1"]?.last?.outcome, .init(ok: false, bytes: 4, text: "boom"))

        work.follow(.gone(answering: [], heard: "n1"))
        XCTAssertNil(work.live)
        XCTAssertEqual(work.steps["n1"]?.count, 2, "the steps stay once the turn is over")
    }

    func testAnEventBetweenTurnsBelongsToNoTurn() {
        let work = TurnWork()
        work.follow(.update(.event(.toolInput(id: "t1", name: "Read", summary: "a", input: "file_path: /a"))))
        XCTAssertTrue(work.steps.isEmpty)
    }

    func testATurnAnsweredAgainStartsItsStepsAgainAndOnlyTheLastFewAreKept() {
        let work = TurnWork()
        run(work, heard: "n1", [.thought(nil)])
        run(work, heard: "n1", [.thought("again")])
        XCTAssertEqual(work.steps["n1"]?.map(\.kind), [.thought(text: "again")])
        for i in 0..<TurnWork.keep { run(work, heard: "m\(i)", [.thought(nil)]) }
        XCTAssertNil(work.steps["n1"], "the oldest turn's steps go past the bound")
        XCTAssertEqual(work.steps.count, TurnWork.keep)
    }

    func testForgettingTakesEverything() {
        let work = TurnWork()
        run(work, heard: "n1", [.thought("x")])
        work.forget()
        XCTAssertTrue(work.steps.isEmpty)
        XCTAssertNil(work.live)
    }
}
