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

    /// The wait itself: it reads the setup until a line fails or every line is done, and gives up
    /// at its deadline with what is still to come.
    @MainActor
    func testTheWaitEndsAtDoneAtAFailureOrAtItsDeadline() async {
        func run(_ sequence: [PerfRun.SetupOutcome], deadline: Duration = .seconds(30)) async -> (PerfRun.SetupOutcome, Int) {
            var reads = 0
            let outcome = await PerfRun.waitForSetup(until: .now + deadline, tick: .milliseconds(1)) {
                defer { reads += 1 }
                return sequence[min(reads, sequence.count - 1)]
            }
            return (outcome, reads)
        }
        let toDone = await run([.waiting(["a", "b"]), .waiting(["b"]), .done, .waiting(["never read"])])
        XCTAssertEqual(toDone.0, .done)
        XCTAssertEqual(toDone.1, 3, "it stops at the first read that is not waiting")
        let toFailure = await run([.waiting(["a"]), .failed("a"), .done])
        XCTAssertEqual(toFailure.0, .failed("a"))
        XCTAssertEqual(toFailure.1, 2)
        let stuck = await run([.waiting(["a"])], deadline: .milliseconds(30))
        XCTAssertEqual(stuck.0, .waiting(["a"]), "the deadline ends it with what is still to come")
        XCTAssertGreaterThan(stuck.1, 1)
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
