import XCTest

@testable import Topo

/// What a launch reads `TOPO_PERF_SEND` as.
final class PerfRunTests: XCTestCase {
    func testTheQuestionsAreAJSONArrayInOrder() {
        XCTAssertEqual(PerfRun.questions(["TOPO_PERF_SEND": #"["what is 6+6?", "What does A || B mean?"]"#]),
                       ["what is 6+6?", "What does A || B mean?"])
    }

    func testBlankQuestionsAreDropped() {
        XCTAssertEqual(PerfRun.questions(["TOPO_PERF_SEND": #"["  ", "one", ""]"#]), ["one"])
    }

    func testAnythingElseIsNoRun() {
        XCTAssertEqual(PerfRun.questions([:]), [])
        XCTAssertEqual(PerfRun.questions(["TOPO_PERF_SEND": "what is 6+6?"]), [])
        XCTAssertEqual(PerfRun.questions(["TOPO_PERF_SEND": #"{"q": "one"}"#]), [])
    }

    /// A timed first run waits while any setup line is still to come, stops at once on a failed
    /// one (nothing retries it without a foreground), and ends done only when every line is.
    @MainActor
    func testAFirstRunsSetupWaitsUntilEveryLineIsDoneOrOneFails() {
        func line(_ title: String, _ state: Setup.State) -> Setup.Line { Setup.Line(title: title, state: state) }
        let downloading = [line(Setup.workspace, .done), line(Setup.hearing, .progress(0.4, "downloading")),
                           line(Setup.speaking, .waiting(Setup.notStarted))]
        XCTAssertEqual(PerfRun.setupOutcome(downloading), .waiting([Setup.hearing, Setup.speaking]))
        let compiling = [line(Setup.workspace, .done), line(Setup.hearing, .working(Ear.preparing)), line(Setup.speaking, .done)]
        XCTAssertEqual(PerfRun.setupOutcome(compiling), .waiting([Setup.hearing]))
        let failed = [line(Setup.workspace, .failed("no room")), line(Setup.hearing, .progress(0.1, "downloading")),
                      line(Setup.speaking, .done)]
        XCTAssertEqual(PerfRun.setupOutcome(failed), .failed(Setup.workspace), "a failure ends the wait though others are still to come")
        let done = [line(Setup.workspace, .done), line(Setup.hearing, .done), line(Setup.speaking, .done)]
        XCTAssertEqual(PerfRun.setupOutcome(done), .done)
        XCTAssertEqual(PerfRun.setupMark(.done, seconds: 312, thermal: 1), "perf.setup.done s=312 thermal=1")
        XCTAssertEqual(PerfRun.setupMark(.failed(Setup.workspace), seconds: 9, thermal: 0), "perf.setup.failed \(Setup.workspace)",
                       "the part, never the reason")
        XCTAssertEqual(PerfRun.setupMark(.waiting([Setup.hearing, Setup.speaking]), seconds: 3000, thermal: 2),
                       "perf.setup.unfinished \(Setup.hearing),\(Setup.speaking)")
    }

    func testTheGapIsFiveSecondsUnlessSaid() {
        XCTAssertEqual(PerfRun.gap([:]), 5)
        XCTAssertEqual(PerfRun.gap(["TOPO_PERF_GAP": "0.5"]), 0.5)
    }

    @MainActor
    func testEachQuestionIsAskedAfterTheReplyToTheLast() async {
        var asked: [String] = []
        let answered = await PerfRun.ask(["one", "two", "three"], gap: .zero) { index, question in
            XCTAssertEqual(asked.count, index)
            asked.append(question)
            return true
        }
        XCTAssertEqual(answered, 3)
        XCTAssertEqual(asked, ["one", "two", "three"])
    }

    @MainActor
    func testTheRunEndsAtTheFirstQuestionWithNoReply() async {
        var asked: [String] = []
        let answered = await PerfRun.ask(["one", "two", "three"], gap: .zero) { _, question in
            asked.append(question)
            return question != "two"
        }
        XCTAssertEqual(answered, 1)
        XCTAssertEqual(asked, ["one", "two"])
    }
}
