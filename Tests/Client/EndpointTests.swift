import XCTest

@testable import Topo

/// Topo's policy over the detector's events (`Endpoint.Policy`): an end with no start ends
/// nothing, a start shorter than `minSpeech` before its end is a cough, and an utterance that has
/// held speech ends at the next end.
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
    /// FluidAudio's segmentation itself needs Silero's model, which the unit suite does not
    /// load: that a 1.5 s pause does not split a sentence is the device check's.
    func testTheSilenceWindowSitsPastTheTwoSecondsThatCutSpeakersOff() {
        XCTAssertEqual(Endpoint.silence, 2.1)
        XCTAssertEqual(Endpoint.minSpeech, 0.25)
        XCTAssertEqual(Endpoint.chunk, 4_096)
        #if canImport(FluidAudio)
        XCTAssertEqual(SileroDetector.silenceWindow, 2.1, "the detector segments on a window other than the promised one")
        #endif
    }

    func testAQuarterSecondAtTheEarsRateIsFourThousandSamples() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(0)), .speech)
        XCTAssertNil(policy.take(.end(3_999)), "under a quarter second ended an utterance")
        XCTAssertEqual(policy.take(.start(10_000)), .speech)
        XCTAssertEqual(policy.take(.end(14_000)), .ended, "a quarter second was not an utterance")
    }
}
