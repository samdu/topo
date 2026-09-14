import XCTest

@testable import Topo

/// The trimmer against a synthetic clip whose gaps are known to the frame: 20 ms frames at
/// 24 kHz are 480 samples, and every region below is laid out in whole frames so the expected
/// lengths are exact.
final class PocketPaceTests: XCTestCase {
    private let rate = 24_000
    private var win: Int { Int(PocketPace.frame * Double(rate)) }

    /// A tone at `level` for `frames` frames; a level of zero is silence.
    private func region(_ frames: Int, level: Float) -> [Float] {
        (0 ..< frames * win).map { level * sin(Float($0) * 0.3) }
    }

    func testTheFrameCountsRoundUpToWholeFrames() {
        XCTAssertEqual(PocketPace.capFrames, 8, "0.15 s is 7.5 frames; the cap is the next whole frame")
        XCTAssertEqual(PocketPace.edgeFrames, 3, "0.05 s is 2.5 frames; the edge is the next whole frame")
    }

    func testAnInnerGapOverTheCapLosesItsExcessFromTheMiddle() {
        // 10 frames of speech, 20 silent, 10 of speech: the gap is cut to the cap.
        let clip = region(10, level: 0.5) + region(20, level: 0) + region(10, level: 0.5)
        let out = PocketPace.trimGaps(clip, rate: rate)
        XCTAssertEqual(out.count, (10 + PocketPace.capFrames + 10) * win)
        // What is left of the gap is its two ends: the samples on either side of the cut are the
        // silence that was there, and the speech either side is untouched.
        XCTAssertEqual(Array(out[0 ..< 10 * win]), Array(clip[0 ..< 10 * win]))
        XCTAssertEqual(Array(out.suffix(10 * win)), Array(clip.suffix(10 * win)))
        XCTAssertTrue(out[10 * win ..< (10 + PocketPace.capFrames) * win].allSatisfy { $0 == 0 })
    }

    func testAnInnerGapWithinTheCapIsLeftAlone() {
        let clip = region(5, level: 0.5) + region(PocketPace.capFrames, level: 0) + region(5, level: 0.5)
        XCTAssertEqual(PocketPace.trimGaps(clip, rate: rate), clip)
    }

    func testTheHeadAndTailKeepUpToTheEdge() {
        // 12 silent frames, 6 of speech, 9 silent: three frames of silence survive at each end.
        let clip = region(12, level: 0) + region(6, level: 0.5) + region(9, level: 0)
        let out = PocketPace.trimGaps(clip, rate: rate)
        XCTAssertEqual(out.count, (PocketPace.edgeFrames + 6 + PocketPace.edgeFrames) * win)
        XCTAssertEqual(Array(out[PocketPace.edgeFrames * win ..< (PocketPace.edgeFrames + 6) * win]),
                       Array(clip[12 * win ..< 18 * win]))
    }

    func testAShortHeadOrTailIsKeptWhole() {
        // One silent frame before the speech and none after: nothing is invented to pad it.
        let clip = region(1, level: 0) + region(4, level: 0.5)
        XCTAssertEqual(PocketPace.trimGaps(clip, rate: rate), clip)
    }

    func testTheThresholdFollowsTheLoudestFrame() {
        // A quiet frame at 1% of the peak is silence; one at 5% is speech and is kept.
        let clip = region(4, level: 1) + region(20, level: 0.01) + region(4, level: 1)
        XCTAssertEqual(PocketPace.trimGaps(clip, rate: rate).count, (4 + PocketPace.capFrames + 4) * win)
        let audible = region(4, level: 1) + region(20, level: 0.05) + region(4, level: 1)
        XCTAssertEqual(PocketPace.trimGaps(audible, rate: rate), audible)
    }

    func testSilenceAndTooShortAClipComeBackAsTheyAre() {
        let silence = region(30, level: 0)
        XCTAssertEqual(PocketPace.trimGaps(silence, rate: rate), silence)
        let short = [Float](repeating: 0.5, count: win - 1)
        XCTAssertEqual(PocketPace.trimGaps(short, rate: rate), short)
    }

    func testTheRemainderPastTheLastWholeFrameIsDropped() {
        // Samples past the last whole frame are not a frame and never counted, at either end.
        let clip = region(4, level: 0.5) + [Float](repeating: 0.5, count: 7)
        XCTAssertEqual(PocketPace.trimGaps(clip, rate: rate), Array(clip.prefix(4 * win)))
    }
}
