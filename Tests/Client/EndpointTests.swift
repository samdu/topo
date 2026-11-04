import XCTest

@testable import Topo

/// Topo's policy over the detector's events (`Endpoint.Policy`): an end with no start ends
/// nothing, a start shorter than `minSpeech` before its end is a cough, and an utterance that has
/// held speech ends at the next end. And Daphne's rule over the quiet and the judge
/// (`Endpoint.Judging`), frame by frame, with the wait it is judged against (`QuietWait`).
final class EndpointTests: XCTestCase {
    private let quarter = Int(Endpoint.minSpeech * Double(Ear.rate))

    func testAnEndWithNoStartEndsNothing() {
        var policy = Endpoint.Policy()
        XCTAssertNil(policy.take(.end(8_000)))
        XCTAssertFalse(policy.speaking)
    }

    func testSpeechAsLongAsTheMinimumIsAnUtterance() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(100)), .speech)
        XCTAssertTrue(policy.speaking)
        XCTAssertEqual(policy.take(.end(100 + quarter)), .ended)
    }

    func testACoughIsNotAnUtteranceButSpeechAfterItIs() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(0)), .speech)
        XCTAssertNil(policy.take(.end(quarter - 1)), "a cough ended the utterance")
        XCTAssertFalse(policy.speaking, "a cough counted as speech")
        XCTAssertEqual(policy.take(.start(20_000)), .speech)
        XCTAssertEqual(policy.take(.end(20_000 + quarter * 4)), .ended)
    }

    func testSilerosSilenceIsTheCapWithAJudgeAndSitsPastTwoSecondsWithout() {
        XCTAssertEqual(Endpoint.silence(judged: true), 4.0)
        XCTAssertGreaterThan(Endpoint.silence(judged: false), 2.0)
        XCTAssertEqual(Endpoint.chunk, Ear.rate * 256 / 1000)
        XCTAssertEqual(Endpoint.Judging.frame, Ear.rate / 10)
    }

    // MARK: - The rule

    typealias Rule = Endpoint.Judging

    /// `frames` quiet frames into `rule`, each ask answered at once with the next of `verdicts`
    /// (the last repeated) against `wait`. Answers how it ended, after how many frames, and the
    /// frames each ask came at.
    private func quiet(_ rule: inout Rule, frames: Int, verdicts: [Float], wait: TimeInterval = 1.2)
        -> (ending: Rule.Ending?, at: Int, asks: [Int]) {
        var asks: [Int] = []
        for frame in 1...frames {
            switch rule.frame(loud: false) {
            case .none: continue
            case .end(let ending): return (ending, frame, asks)
            case .ask(let n):
                asks.append(frame)
                let p = verdicts[min(asks.count - 1, verdicts.count - 1)]
                if case .end(let ending) = rule.verdict(p, ask: n, wait: wait) { return (ending, frame, asks) }
            }
        }
        return (nil, frames, asks)
    }

    func testTwoCompleteVerdictsAfterTheWaitEnd() {
        var rule = Rule()
        let run = quiet(&rule, frames: 40, verdicts: [0.9])
        XCTAssertEqual(run.ending, .judged(p: 0.9, quiet: 1.2))
        XCTAssertEqual(run.at, 12, "the turn ended other than at the wait")
    }

    func testTwoCompleteVerdictsBeforeTheWaitEndNothing() {
        var rule = Rule()
        let run = quiet(&rule, frames: 11, verdicts: [0.9])
        XCTAssertNil(run.ending, "two complete verdicts ended the turn at \(run.at) frames, inside a 1.2 s wait")
        XCTAssertEqual(run.asks, [4, 6, 8, 10])
        XCTAssertEqual(rule.votes, 4)
    }

    func testTheWaitIsReadAtEachVerdict() {
        var rule = Rule()
        var steps: [Rule.Step] = []
        for frame in 1...10 {
            guard case .ask(let n) = rule.frame(loud: false) else { continue }
            // Long while the first verdicts land; shortened before the one at a second.
            steps.append(rule.verdict(0.9, ask: n, wait: frame < 10 ? 3.0 : 1.0))
        }
        XCTAssertEqual(steps, [.none, .none, .none, .end(.judged(p: 0.9, quiet: 1.0))])
    }

    func testALowVerdictBetweenTwoHighOnesEndsNothing() {
        var rule = Rule()
        let run = quiet(&rule, frames: 18, verdicts: [0.2, 0.2, 0.2, 0.2, 0.9, 0.2, 0.9, 0.9])
        // Asks at 4…18: the high ones at 12, 16 and 18; the low at 14 between the first two.
        XCTAssertEqual(run.asks, [4, 6, 8, 10, 12, 14, 16, 18])
        XCTAssertEqual(run.ending, .judged(p: 0.9, quiet: 1.8), "high, low, high ended the turn")
        XCTAssertEqual(run.at, 18)
    }

    func testAVerdictFromBeforeSpeechResumedCountsForNothing() {
        var rule = Rule()
        var asked: Int?
        for _ in 1...4 { if case .ask(let n) = rule.frame(loud: false) { asked = n } }
        let stale = try! XCTUnwrap(asked)
        XCTAssertEqual(rule.frame(loud: true), .none)
        XCTAssertEqual(rule.quietFrames, 0, "speech did not set the quiet back")
        // Twelve frames of quiet with the stale ask still in flight: nothing more is asked.
        for _ in 1...12 { XCTAssertEqual(rule.frame(loud: false), .none) }
        XCTAssertEqual(rule.verdict(0.95, ask: stale, wait: 1.2), .none)
        XCTAssertEqual(rule.votes, 0, "a verdict asked before speech resumed was a vote")
        // The next two asks, at 1.4 s and 1.6 s of quiet, are the two in a row.
        XCTAssertEqual(rule.frame(loud: false), .none)
        guard case .ask(let next) = rule.frame(loud: false) else { return XCTFail("nothing asked") }
        XCTAssertEqual(rule.verdict(0.95, ask: next, wait: 1.2), .none, "one vote ended the turn")
        XCTAssertEqual(rule.frame(loud: false), .none)
        guard case .ask(let last) = rule.frame(loud: false) else { return XCTFail("nothing asked") }
        XCTAssertEqual(rule.verdict(0.95, ask: last, wait: 1.2), .end(.judged(p: 0.95, quiet: 1.6)))
    }

    func testVotesAreKeptAcrossResumedSpeech() {
        var rule = Rule()
        _ = quiet(&rule, frames: 4, verdicts: [0.9])
        XCTAssertEqual(rule.votes, 1)
        _ = rule.frame(loud: true)
        XCTAssertEqual(rule.votes, 1, "speech resuming cleared the votes, which Daphne keeps")
    }

    func testFortyQuietFramesEndWhateverTheJudgeSays() {
        var rule = Rule()
        let run = quiet(&rule, frames: 60, verdicts: [0.1])
        XCTAssertEqual(run.ending, .quiet(4.0))
        XCTAssertEqual(run.at, 40)
        XCTAssertEqual(rule.lastVerdict, 0.1)
        var unasked = Rule()
        var step = Rule.Step.none
        for _ in 1...40 { step = unasked.frame(loud: false) }
        XCTAssertEqual(step, .end(.quiet(4.0)), "the cap waited on a verdict in flight")
    }

    func testAsksFromFourQuietFramesEveryTwoOneInFlight() {
        var rule = Rule()
        var asks: [Int: Int] = [:]
        for frame in 1...12 {
            if case .ask(let n) = rule.frame(loud: false) { asks[frame] = n }
            // The first ask is answered only at the seventh frame.
            if frame == 7, let first = asks[4] { _ = rule.verdict(0.1, ask: first, wait: 1.2) }
        }
        XCTAssertEqual(asks.keys.sorted(), [4, 8], "asked other than from four frames, every two, one at a time")
        XCTAssertEqual(asks.count, Set(asks.values).count, "two asks shared a number")
        XCTAssertNotNil(rule.inFlight)
    }

    func testAVerdictAtExactlyTheThresholdIsNotAVote() {
        var rule = Rule()
        let run = quiet(&rule, frames: 40, verdicts: [0.85])
        XCTAssertEqual(rule.votes, 0)
        XCTAssertEqual(run.ending, .quiet(4.0), "0.85 is not over 0.85")
        var over = Rule()
        XCTAssertEqual(quiet(&over, frames: 40, verdicts: [0.851]).ending, .judged(p: 0.851, quiet: 1.2))
    }

    func testAnUnansweredAskLetsTheNextGo() {
        var rule = Rule()
        var asks: [Int] = []
        for _ in 1...6 {
            if case .ask(let n) = rule.frame(loud: false) { asks.append(n); rule.unanswered(ask: n) }
        }
        XCTAssertEqual(asks.count, 2, "a judge that threw held the next ask back")
        XCTAssertEqual(rule.votes, 0)
    }

    func testTheGateIsMinusThirtyEightDBFS() {
        func frame(_ level: Float) -> ArraySlice<Float> { ArraySlice((0..<1_600).map { $0.isMultiple(of: 2) ? level : -level }) }
        XCTAssertTrue(Endpoint.loud(frame(0.0135)), "-37.4 dBFS was not loud")
        XCTAssertFalse(Endpoint.loud(frame(0.0125)), "-38.1 dBFS was not quiet")
        XCTAssertFalse(Endpoint.loud(frame(0)))
    }

    // MARK: - The wait

    func testQuietWaitOutOfRangeOrABooleanIsTheStandard() {
        let defaults = UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
        XCTAssertEqual(QuietWait.value(defaults), 1.2)
        for kept: Any in [0.5, 3.1, -1.0, Double.nan, Double.infinity, "2.0", Data(), true, false] {
            defaults.set(kept, forKey: QuietWait.key)
            XCTAssertEqual(QuietWait.value(defaults), 1.2, "\(kept)")
        }
        for (kept, read) in [(0.6, 0.6), (3.0, 3.0), (2.0, 2.0), (0.6 + 0.2 * 12, 3.0), (1.4000000000000001, 1.4)] {
            defaults.set(kept, forKey: QuietWait.key)
            XCTAssertEqual(QuietWait.value(defaults), read, "what the stepper writes: \(kept)")
        }
        XCTAssertEqual(QuietWait.said(1.2), "1.2")
    }
}
