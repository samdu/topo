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

    func testTheGapIsFiveSecondsUnlessSaid() {
        XCTAssertEqual(PerfRun.gap([:]), 5)
        XCTAssertEqual(PerfRun.gap(["TOPO_PERF_GAP": "0.5"]), 0.5)
    }
}
