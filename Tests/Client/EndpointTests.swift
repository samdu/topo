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

    func testTheSilenceWindowSitsPastTheTwoSecondsThatCutSpeakersOff() {
        XCTAssertGreaterThan(Endpoint.silence, 2.0)
        XCTAssertEqual(Endpoint.chunk, Ear.rate * 256 / 1000)
    }
}
