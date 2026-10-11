import XCTest

@testable import TopoTurn

/// The compaction setting and Claude Code's arithmetic at its pin (2.1.285): the threshold is
/// `min(floor(e * pct / 100), e - 13000)` over `e`, the window less 20 000.
final class CompactionTests: XCTestCase {
    func testTheOneReaderTakesAutoAndWholePercentsInRange() {
        XCTAssertEqual(Compaction.Setting("auto"), .auto)
        XCTAssertEqual(Compaction.Setting(" AUTO "), .auto)
        XCTAssertEqual(Compaction.Setting("25"), .percent(25))
        XCTAssertEqual(Compaction.Setting("80%"), .percent(80))
        XCTAssertEqual(Compaction.Setting("100"), .percent(100))
        for word in ["0", "9", "24", "101", "12.5", "nan", "NaN", "eighty", "-50", "+50", "5e1", "", "%", "٥٠", "50 %"] {
            XCTAssertNil(Compaction.Setting(word), word)
        }
    }

    func testWhatIsKeptReadsBackAndANumberNoSettingReadsAsIsAuto() {
        for setting in [Compaction.Setting.auto, .percent(25), .percent(83), .percent(100)] {
            XCTAssertEqual(Compaction.Setting(kept: setting.kept), setting)
        }
        for kept in [-1, 1, 24, 101, Int.max] { XCTAssertEqual(Compaction.Setting(kept: kept), .auto, "\(kept)") }
        XCTAssertNil(Compaction.Setting.auto.percent)
        XCTAssertEqual(Compaction.Setting.percent(60).word, "60%")
    }

    func testTheThresholdIsThePinsFormula() {
        XCTAssertEqual(Compaction.threshold(window: 200_000, setting: .auto), 167_000)
        XCTAssertEqual(Compaction.threshold(window: 200_000, setting: .percent(25)), 45_000)
        XCTAssertEqual(Compaction.threshold(window: 200_000, setting: .percent(50)), 90_000)
        XCTAssertEqual(Compaction.threshold(window: 200_000, setting: .percent(95)), 167_000, "a percent raised the threshold over Claude Code's own")
        XCTAssertEqual(Compaction.threshold(window: 200_000, setting: .percent(100)), 167_000)
        XCTAssertEqual(Compaction.threshold(window: 1_000_000, setting: .auto), 967_000)
        XCTAssertEqual(Compaction.threshold(window: 1_000_000, setting: .percent(25)), 245_000)
        XCTAssertEqual(Compaction.threshold(window: 1_000_000, setting: .percent(50)), 490_000)
        XCTAssertEqual(Compaction.threshold(window: 1_000_000, setting: .percent(95)), 931_000)
        XCTAssertEqual(Compaction.threshold(window: 1_000_000, setting: .percent(100)), 967_000)
        XCTAssertEqual(Compaction.threshold(window: 10_000, setting: .auto), 0, "a window under what is reserved went negative")
    }

    func testTheLoadIsTheThresholdsScale() {
        XCTAssertEqual(Compaction.load(context: 0, window: 200_000, setting: .auto), .default)
        XCTAssertEqual(Compaction.load(context: 125_249, window: 200_000, setting: .auto), .default)
        XCTAssertEqual(Compaction.load(context: 125_250, window: 200_000, setting: .auto), .warning)
        XCTAssertEqual(Compaction.load(context: 167_000, window: 200_000, setting: .auto), .reset)
        XCTAssertEqual(Compaction.load(context: 44_999, window: 200_000, setting: .percent(25)), .warning)
        XCTAssertEqual(Compaction.load(context: 45_000, window: 200_000, setting: .percent(25)), .reset)
        XCTAssertEqual(Compaction.load(context: 5, window: 10_000, setting: .auto), .default)
    }

    func testAnOutcomeSaysWhatItCameTo() {
        XCTAssertEqual(Compaction.Outcome.done(pre: 31_502, post: 1_471).words, "31502 → 1471 tokens")
        XCTAssertEqual(Compaction.Outcome.failed("too_few_groups").words, "failed: too_few_groups")
        XCTAssertEqual(Compaction.Outcome.unavailable("the guest is not up").words, "not run: the guest is not up")
    }
}
