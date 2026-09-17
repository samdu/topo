import XCTest

@testable import Topo

/// The trimmer against a synthetic sentence whose gaps are known to the window, fed as Pocket
/// feeds it: 1920-sample frames at 24 kHz, four 20 ms windows each, so every region below is a
/// whole number of windows and the expected lengths are exact.
///
/// Each case states what it expects, rather than measuring the trimmer against another cut of
/// the same audio: the threshold is the loudest window heard *so far*, which is a different
/// function from one that knows the whole sentence before it starts.
final class PocketPaceTests: XCTestCase {
    private let rate = 24_000
    private let frame = 1_920
    private var win: Int { Int(PocketPace.frame * Double(rate)) }

    /// A tone at `level` for `windows` windows; a level of zero is silence.
    private func region(_ windows: Int, level: Float) -> [Float] {
        (0 ..< windows * win).map { level * sin(Float($0) * 0.3) }
    }

    /// The whole of `clip` through the trimmer in 1920-sample frames, as the voice delivers it.
    private func trimmed(_ clip: [Float], loudest: Float = 0) -> [Float] {
        var trim = PocketPace(loudest: loudest)
        var out: [Float] = []
        for start in stride(from: 0, to: clip.count, by: frame) {
            out += trim.take(Array(clip[start ..< min(start + frame, clip.count)]), rate: rate)
        }
        trim.finish()
        return out
    }

    func testTheWindowCountsRoundUpToWholeWindows() {
        XCTAssertEqual(PocketPace.capFrames, 8, "0.15 s is 7.5 windows; the cap is the next whole one")
        XCTAssertEqual(PocketPace.edgeFrames, 3, "0.05 s is 2.5 windows; the edge is the next whole one")
    }

    func testAnInnerGapOverTheCapIsCutToTheCapFromItsMiddle() {
        // 8 windows of speech, 20 silent, 8 of speech: the gap comes out at the cap, its two
        // ends kept and the middle gone.
        let clip = region(8, level: 0.5) + region(20, level: 0) + region(8, level: 0.5)
        let out = trimmed(clip)
        XCTAssertEqual(out.count, (8 + PocketPace.capFrames + 8) * win)
        XCTAssertEqual(Array(out[0 ..< 8 * win]), Array(clip[0 ..< 8 * win]))
        XCTAssertEqual(Array(out.suffix(8 * win)), Array(clip.suffix(8 * win)))
        XCTAssertTrue(out[8 * win ..< (8 + PocketPace.capFrames) * win].allSatisfy { $0 == 0 })
    }

    func testAnInnerGapWithinTheCapIsLeftAlone() {
        let clip = region(8, level: 0.5) + region(PocketPace.capFrames, level: 0) + region(8, level: 0.5)
        XCTAssertEqual(trimmed(clip), clip)
    }

    /// The gap above starts on a frame boundary; this one starts two windows into a frame and
    /// ends two windows into another. Same gap, cut to the same cap.
    func testAGapStraddlingAFrameBoundaryIsCutTheSameAsOneInsideAFrame() {
        let clip = region(2, level: 0.5) + region(21, level: 0) + region(8, level: 0.5)
        let out = trimmed(clip)
        XCTAssertEqual(out.count, (2 + PocketPace.capFrames + 8) * win)
        XCTAssertTrue(out[2 * win ..< (2 + PocketPace.capFrames) * win].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(out.suffix(8 * win)), Array(clip.suffix(8 * win)))
    }

    func testTheHeadAndTailKeepUpToTheEdge() {
        // 12 silent windows, 8 of speech, 12 silent: three windows of silence survive at each end.
        let clip = region(12, level: 0) + region(8, level: 0.5) + region(12, level: 0)
        let out = trimmed(clip)
        XCTAssertEqual(out.count, (PocketPace.edgeFrames + 8 + PocketPace.edgeFrames) * win)
        XCTAssertEqual(Array(out[PocketPace.edgeFrames * win ..< (PocketPace.edgeFrames + 8) * win]),
                       Array(clip[12 * win ..< 20 * win]))
    }

    func testAHeadShorterThanTheEdgeIsKeptWhole() {
        // One silent window before the speech: nothing is invented to pad it.
        let clip = region(1, level: 0) + region(7, level: 0.5)
        XCTAssertEqual(trimmed(clip), clip)
    }

    /// Speech is never held: the first frame's words are out before the last frame is in.
    func testSamplesAreEmittedBeforeTheEndOfTheStream() {
        var trim = PocketPace()
        let speech = region(4, level: 0.5)
        let first = trim.take(speech, rate: rate)
        XCTAssertEqual(first, speech, "the frame that carries speech goes out whole, at once")
        XCTAssertEqual(trim.take(region(4, level: 0), rate: rate).count, PocketPace.edgeFrames * win,
                       "only the edge of the silence behind it follows")
    }

    /// The whole difference from a cut over a finished clip: the threshold is the loudest window
    /// so far, so an opening this quiet is speech when it arrives and is kept.
    func testAQuietOpeningFollowedByLoudSpeechIsKept() {
        let clip = region(8, level: 0.01) + region(8, level: 1)
        XCTAssertEqual(trimmed(clip), clip)
    }

    func testTheThresholdFollowsTheLoudestWindow() {
        // Behind a loud opening, 1% of the peak is silence and 5% is speech.
        let quiet = region(8, level: 1) + region(20, level: 0.01) + region(8, level: 1)
        XCTAssertEqual(trimmed(quiet).count, (8 + PocketPace.capFrames + 8) * win)
        let audible = region(8, level: 1) + region(20, level: 0.05) + region(8, level: 1)
        XCTAssertEqual(trimmed(audible), audible)
    }

    func testASentenceOfSilenceComesBackAsAtMostTheEdge() {
        // Nothing ever started, so nothing is released and the tail is dropped at `finish`.
        XCTAssertEqual(trimmed(region(32, level: 0)), [])
    }

    func testTheRemainderPastTheLastWholeWindowIsDropped() {
        var trim = PocketPace()
        let out = trim.take(region(4, level: 0.5) + [Float](repeating: 0.5, count: 7), rate: rate)
        XCTAssertEqual(out.count, 4 * win, "seven samples are not a window and wait for the next frame")
        trim.finish()
        XCTAssertEqual(trim.dropped, 7)
    }
}
