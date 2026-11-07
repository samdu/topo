import XCTest
#if canImport(FluidAudio)
import FluidAudio
#endif

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

    /// The promised numbers as literals, so a change to any of them is a change to this test.
    /// That a 1.5 s pause does not split a sentence is FluidAudio's segmentation on speech,
    /// which is the device check's: `SileroLoadTests` loads the model and feeds it silence alone.
    func testSilerosSilenceIsTheCapWithAJudgeAndSitsPastTwoSecondsWithout() {
        XCTAssertEqual(Endpoint.silence(judged: true), 4.0)
        XCTAssertEqual(Endpoint.silence(judged: false), 2.1)
        XCTAssertEqual(Endpoint.minSpeech, 0.25)
        XCTAssertEqual(Endpoint.chunk, 4_096)
        XCTAssertEqual(Endpoint.chunk, Ear.rate * 256 / 1000)
        XCTAssertEqual(Endpoint.Judging.frame, Ear.rate / 10)
    }

    func testAQuarterSecondAtTheEarsRateIsFourThousandSamples() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(0)), .speech)
        XCTAssertNil(policy.take(.end(3_999)), "under a quarter second ended an utterance")
        XCTAssertEqual(policy.take(.start(10_000)), .speech)
        XCTAssertEqual(policy.take(.end(14_000)), .ended, "a quarter second was not an utterance")
    }

    /// Under a tone sounded into the microphone the gate is shut (Daphne's `holdGate`): an onset
    /// inside it is not one, and speech counts toward the minimum only past it, so a tone longer
    /// than the minimum is no utterance, while words that run on past the gate are. An onset
    /// before the gate is the person's, whenever its verdict arrives.
    @MainActor
    func testSpeechInsideTheGateIsTheTonesAndOnlyWhatRunsPastItCounts() {
        let gate = 0..<6_400
        var policy = Endpoint.Policy()
        XCTAssertNil(policy.take(.start(0), gates: [gate]), "an onset inside the gate was one")
        XCTAssertNil(policy.take(.end(6_000), gates: [gate]), "a tone longer than the minimum was an utterance")
        XCTAssertFalse(policy.speaking)

        XCTAssertNil(policy.take(.start(100), gates: [gate]))
        let late = gate.upperBound + Endpoint.startEarly
        XCTAssertNil(policy.take(.end(late + quarter - 1), gates: [gate]),
                     "speech under the gate, or the detector's lateness past it, was counted")
        XCTAssertNil(policy.take(.start(200), gates: [gate]))
        XCTAssertEqual(policy.take(.end(late + quarter), gates: [gate]), .ended,
                       "words running on past the gate were lost")

        var past = Endpoint.Policy()
        XCTAssertEqual(past.take(.start(gate.upperBound), gates: [gate]), .speech, "an onset as the gate opens was not one")

        // A tone sounded at sample 30 000, its onset as early as the detector can put it: words
        // begun before that, judged before or after the tone, are the person's and counted whole.
        XCTAssertEqual(Endpoint.startEarly, Endpoint.chunk + 1_600,
                       "the gate does not reach as far as the detector can put a tone's onset and end")
        let tone = (30_000 - Endpoint.startEarly)..<36_400
        var before = Endpoint.Policy()
        XCTAssertEqual(before.take(.start(4_096), gates: [tone]), .speech, "words begun before the tone were taken for it")
        XCTAssertEqual(before.take(.end(4_096 + quarter), gates: [tone]), .ended,
                       "a tone sounded over words already begun took them")
        var early = Endpoint.Policy()
        XCTAssertNil(early.take(.start(tone.lowerBound), gates: [tone]), "the tone's own onset, reported early, was speech")
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

#if canImport(FluidAudio)
/// The detector as the app loads it: Silero's real model, fetched by the suite from the manifest's
/// pinned revision (`scripts/fetch-ear-models.sh`), laid where the app's own store keeps it
/// (`ModelStore.standard(support:)`, `directory(for:)`), and loaded by `Endpoint.silero`, the
/// loader `Endpoint.prepare` runs. `Endpoint(detector:)`, which the conversation's suite uses,
/// passes over all three.
final class SileroLoadTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("topo-silero-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func vad() throws -> ModelManifest.Model {
        try XCTUnwrap(ModelManifest.bundled().models.first { $0.id == ModelManifest.vad })
    }

    func testTheDetectorLoadsFromWhereTheStoreKeepsIt() async throws {
        let fetched = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TOPO_UNIT_EAR_MODELS"].flatMap { $0.isEmpty ? nil : $0 },
            "Silero's model in TEST_RUNNER_TOPO_UNIT_EAR_MODELS")
        let model = try vad()
        let store = ModelStore.standard(support: support)
        let directory = store.directory(for: model)
        let source = URL(fileURLWithPath: fetched).appendingPathComponent(ModelManifest.vad)
        for file in model.files {
            let to = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(file.path), to: to)
        }

        let detector = try await Endpoint.silero(directory)
        let quiet = [Float](repeating: 0, count: Endpoint.chunk)
        for _ in 0..<4 {
            let event = try await detector.feed(quiet)
            XCTAssertNil(event, "silence began or ended an utterance")
        }
    }

    /// The silence a stream is reset with is the one the real detector segments on: the cap with a
    /// judge, the end without.
    func testTheRealDetectorSegmentsOnTheSilenceItWasResetWith() async throws {
        let fetched = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TOPO_UNIT_EAR_MODELS"].flatMap { $0.isEmpty ? nil : $0 },
            "Silero's model in TEST_RUNNER_TOPO_UNIT_EAR_MODELS")
        let model = try vad()
        let directory = ModelStore.standard(support: support).directory(for: model)
        let source = URL(fileURLWithPath: fetched).appendingPathComponent(ModelManifest.vad)
        for file in model.files {
            let to = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(file.path), to: to)
        }
        let loaded = try await Endpoint.silero(directory)
        let detector = try XCTUnwrap(loaded as? SileroDetector)
        for judged in [true, false] {
            await detector.reset(silence: Endpoint.silence(judged: judged))
            let silence = await detector.silence
            XCTAssertEqual(silence, Endpoint.silence(judged: judged))
        }
    }

    /// With nothing where the store keeps the model, the load fails rather than fetching the
    /// model over a session of FluidAudio's own.
    func testADetectorNotInTheStoreIsAFailureAndNotAFetch() async throws {
        let directory = ModelStore.standard(support: support).directory(for: try vad())
        do {
            _ = try await Endpoint.silero(directory)
            XCTFail("loaded a detector the store does not have")
        } catch DownloadError.modelMissing {
            // Offline, the missing file is said as missing; online it would have been fetched,
            // or failed as the network's.
        } catch {
            XCTFail("not refused as missing: \(error)")
        }
        let models = support.appendingPathComponent("Models")
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: models.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix(".mlmodelc") }, "fetched \(left)")
    }
}
#endif
