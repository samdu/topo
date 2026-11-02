import XCTest

@testable import Topo

/// The watchdog over fake tasks: what it cancels, when it makes the replacement, and what it
/// leaves alone. Every instant is handed in, so nothing here waits.
@MainActor
final class DownloadWatchdogTests: XCTestCase {
    private let t0 = ContinuousClock.Instant.now
    private let KB: Int64 = 1024
    private let MB: Int64 = 1024 * 1024

    private func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    /// A task flowing at `rate` bytes a second, sampled every second from `from` to `to`.
    private func flow(_ dog: DownloadWatchdog, _ key: String, rate: Int64, from: Int, to: Int, start: Int64 = 0) {
        for s in from...to { dog.observe(key, bytes: start + rate * Int64(s - from), at: at(Double(s))) }
    }

    func testAStalledTaskIsCancelledOnceAWindowOfSamplesExistsAndNotBefore() throws {
        let dog = DownloadWatchdog()
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 19)
        XCTAssertEqual(dog.decisions(at: at(19)), [], "19 s of samples is less than a window")
        XCTAssertTrue(dog.active)
        dog.observe("m|f", bytes: 36 * KB * 20, at: at(20))
        let cancels = dog.decisions(at: at(20))
        XCTAssertEqual(cancels.count, 1)
        let cancel = try XCTUnwrap(cancels.first)
        XCTAssertEqual(cancel.key, "m|f")
        XCTAssertEqual(cancel.attempt, 1)
        XCTAssertLessThanOrEqual(abs(cancel.rate - 36 * KB), KB)
        XCTAssertTrue(dog.restarting("m|f"), "between its cancel and its replacement the key is restarting")
        XCTAssertEqual(dog.decisions(at: at(25)), [], "a cancel is recorded as it is decided, not when the relay answers")
    }

    func testAFastTaskAndOneWithNoFirstByteAreLeftAlone() {
        let dog = DownloadWatchdog()
        flow(dog, "m|fast", rate: 2 * MB, from: 0, to: 60)
        XCTAssertEqual(dog.decisions(at: at(60)), [])
        XCTAssertEqual(dog.kept("m|none"), 0, "a task with no first byte has no samples, and is not judged")
    }

    func testSilenceAfterAFirstByteIsSlow() {
        let dog = DownloadWatchdog()
        dog.observe("m|f", bytes: 5 * MB, at: at(0))
        XCTAssertEqual(dog.decisions(at: at(20)).map(\.rate), [0], "no bytes since the anchor is a rate of zero")
        // Bytes that went down (a count read off a task made from nothing) are a rate of zero,
        // not a negative one.
        let down = DownloadWatchdog()
        down.observe("m|g", bytes: 5 * MB, at: at(0))
        down.observe("m|g", bytes: 1 * MB, at: at(20))
        XCTAssertEqual(down.decisions(at: at(20)).map(\.rate), [0])
    }

    func testASiblingWithSamplesButNoWindowYetDefersTheJudgement() {
        // The encoder's task has been crawling for a window when the voice's starts beside it:
        // the voice's rate is the comparison, and it is a few ticks away.
        let dog = DownloadWatchdog()
        flow(dog, "m|a", rate: 36 * KB, from: 0, to: 20)
        flow(dog, "m|b", rate: 2 * MB, from: 15, to: 20)
        XCTAssertEqual(dog.decisions(at: at(20)), [], "a sibling with samples and no window yet holds the judgement")
        flow(dog, "m|a", rate: 36 * KB, from: 21, to: 35, start: 36 * KB * 21)
        flow(dog, "m|b", rate: 2 * MB, from: 21, to: 35, start: 2 * MB * 6)
        XCTAssertEqual(dog.decisions(at: at(35)).map(\.key), ["m|a"], "once the sibling has a window, the crawl is judged against it")
    }

    func testAKeyWhoseReplacementHadNoResumeDataIsNotCancelledAgain() {
        let dog = DownloadWatchdog()
        dog.restarted("m|f", resumed: false)
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 20)
        XCTAssertEqual(dog.decisions(at: at(20)), [], "a second start from nothing is a loss, not a retry")
        dog.forget("m|f")
        flow(dog, "m|f", rate: 36 * KB, from: 30, to: 50)
        XCTAssertEqual(dog.decisions(at: at(50)).map(\.key), ["m|f"], "forgotten, the key starts clean")
        let resumed = DownloadWatchdog()
        resumed.restarted("m|g", resumed: true)
        flow(resumed, "m|g", rate: 36 * KB, from: 0, to: 20)
        XCTAssertEqual(resumed.decisions(at: at(20)).map(\.key), ["m|g"], "a replacement with resume data is judged as any task")
    }

    func testSlowIsUnderTheFloorAndUnderATenthOfTheFastestSibling() {
        // Six connections on one thin link: all under the floor, none a tenth of another.
        let dog = DownloadWatchdog()
        for i in 0..<6 { flow(dog, "m|\(i)", rate: 250 * KB, from: 0, to: 20) }
        XCTAssertEqual(dog.decisions(at: at(20)), [], "a shared link is not a slow connection")
        // A crawl beside a fast neighbour is the connection's own.
        let two = DownloadWatchdog()
        flow(two, "m|crawl", rate: 40 * KB, from: 0, to: 20)
        flow(two, "m|fast", rate: 30 * MB, from: 0, to: 20)
        XCTAssertEqual(two.decisions(at: at(20)).map(\.key), ["m|crawl"])
        // Alone, the floor decides.
        XCTAssertTrue(DownloadWatchdog.slow(40 * KB, among: [Int64]()))
        XCTAssertFalse(DownloadWatchdog.slow(300 * KB, among: [Int64]()))
        XCTAssertFalse(DownloadWatchdog.slow(40 * KB, among: [300 * KB]), "under the floor but over a tenth of its sibling")
        XCTAssertTrue(DownloadWatchdog.slow(20 * KB, among: [300 * KB]))
    }

    func testTheReplacementIsJudgedOnItsOwnSamplesAndTheBackoffGrowsThenCoolsDown() {
        let dog = DownloadWatchdog()
        var now = 0
        var bytes: Int64 = 0
        let delays = [0, 15, 30, 60]
        for attempt in 1...4 {
            // Twenty seconds of crawl, judged at ten (nothing: for a replacement, the proof that
            // it is judged on its own samples) and at twenty (the cancel).
            flow(dog, "m|f", rate: 36 * KB, from: now, to: now + 10, start: bytes)
            bytes += 36 * KB * 10
            XCTAssertEqual(dog.decisions(at: at(Double(now + 10))), [], "attempt \(attempt): ten seconds of samples is less than a window")
            flow(dog, "m|f", rate: 36 * KB, from: now + 10, to: now + 20, start: bytes)
            bytes += 36 * KB * 10
            now += 20
            XCTAssertEqual(dog.decisions(at: at(Double(now))).map(\.attempt), [attempt], "attempt \(attempt) cancelled at \(now) s")
            XCTAssertTrue(dog.cancelled("m|f", at: at(Double(now))))
            XCTAssertFalse(dog.cancelled("m|f", at: at(Double(now))), "a second word of the same cancel is late")
            XCTAssertTrue(dog.active, "a restart owed keeps the watchdog awake")
            let delay = delays[attempt - 1]
            if delay > 0 {
                XCTAssertEqual(dog.restartsDue(at: at(Double(now + delay - 1))), [], "attempt \(attempt): not yet")
                XCTAssertTrue(dog.restarting("m|f"), "owed a replacement, the key is still restarting")
            }
            XCTAssertEqual(dog.restartsDue(at: at(Double(now + delay))), ["m|f"], "attempt \(attempt): \(delay) s after its cancel")
            XCTAssertEqual(dog.restartsDue(at: at(Double(now + delay))), [], "made once")
            XCTAssertFalse(dog.restarting("m|f"))
            now += delay
        }
        let fourth = now - 60
        // Past the four, the next cancel waits for the cooldown from the last.
        flow(dog, "m|f", rate: 36 * KB, from: now, to: now + 20, start: bytes)
        XCTAssertEqual(dog.decisions(at: at(Double(now + 20))), [], "within the cooldown of the fourth cancel")
        let later = fourth + 300
        flow(dog, "m|f", rate: 36 * KB, from: later, to: later + 20, start: bytes)
        XCTAssertEqual(dog.decisions(at: at(Double(later + 20))).map(\.attempt), [5], "after the cooldown, once more")
        dog.cancelled("m|f", at: at(Double(later + 20)))
        XCTAssertEqual(dog.restartsDue(at: at(Double(later + 20))), ["m|f"], "past the four the cooldown spaces the cancels, and the replacement is made at once")
    }

    func testAForgottenKeyIsGoneAndTheWatchdogSleeps() {
        let dog = DownloadWatchdog()
        XCTAssertFalse(dog.active)
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 20)
        XCTAssertTrue(dog.active)
        dog.forget("m|f")
        XCTAssertFalse(dog.active)
        XCTAssertEqual(dog.decisions(at: at(20)), [])
        // Forgotten between its cancel and its replacement: no replacement is owed.
        flow(dog, "m|g", rate: 36 * KB, from: 0, to: 20)
        XCTAssertEqual(dog.decisions(at: at(20)).count, 1)
        dog.forget("m|g")
        XCTAssertFalse(dog.cancelled("m|g", at: at(21)))
        XCTAssertFalse(dog.active)
    }

    func testTheWindowIsAllAKeyKeeps() {
        let dog = DownloadWatchdog()
        for tenth in 0..<3000 { dog.observe("m|f", bytes: Int64(tenth) * 100 * KB, at: t0 + .milliseconds(tenth * 100)) }
        XCTAssertLessThanOrEqual(dog.kept("m|f"), 202, "a window of samples at ten a second, and the anchor")
    }

    func testTheTimeAwayIsJudgedAsOneSpanAndNothingFromBeforeItCounts() {
        let dog = DownloadWatchdog()
        flow(dog, "m|crawl", rate: 36 * KB, from: 0, to: 10, start: 0)
        flow(dog, "m|fast", rate: 20 * MB, from: 0, to: 10, start: 0)
        dog.resigned(at: at(10))
        XCTAssertFalse(dog.active, "nothing is sampled while the app is away")
        // Sixty seconds locked: the crawl went on crawling, the fast one flew.
        let cancels = dog.probe(["m|crawl": 36 * KB * 10 + 36 * KB * 60, "m|fast": 20 * MB * 10 + 20 * MB * 60], at: at(70))
        XCTAssertEqual(cancels.map(\.key), ["m|crawl"])
        XCTAssertLessThanOrEqual(abs(cancels[0].rate - 36 * KB), KB)
        // What was sampled before the resign is not evidence now: the fast one needs a window
        // of new samples before it is judged at all, slow or not.
        XCTAssertEqual(dog.decisions(at: at(70)), [])
        dog.observe("m|fast", bytes: 0, at: at(70))
        XCTAssertEqual(dog.decisions(at: at(89)), [], "19 s of new samples")
        XCTAssertEqual(dog.decisions(at: at(90)).map(\.key), ["m|fast"], "20 s of silence after the return is a judgement of its own")
    }

    func testAShortTimeAwayAndATaskTheSessionNoLongerHoldsAreNotJudged() {
        let dog = DownloadWatchdog()
        flow(dog, "m|crawl", rate: 36 * KB, from: 0, to: 10)
        dog.resigned(at: at(10))
        XCTAssertEqual(dog.probe(["m|crawl": 36 * KB * 29], at: at(29)), [], "less than a window away")
        flow(dog, "m|crawl", rate: 36 * KB, from: 29, to: 40)
        dog.resigned(at: at(40))
        XCTAssertEqual(dog.probe([:], at: at(100)), [], "a task the session no longer holds is not in the probe")
    }

    func testACancelInFlightAndAReplacementOwedAreKeptAcrossTheTimeAway() {
        let dog = DownloadWatchdog()
        // Cancelled at 20, resigned before the relay answers: the answer still counts, and the
        // replacement it owes (the second's, after 15 s) is due on the first tick after the return.
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 20)
        XCTAssertEqual(dog.decisions(at: at(20)).count, 1)
        dog.resigned(at: at(21))
        XCTAssertTrue(dog.restarting("m|f"), "a cancel in flight is kept across the resign")
        XCTAssertEqual(dog.probe([:], at: at(100)), [], "a key not in the probe is gone, or restarting")
        XCTAssertTrue(dog.cancelled("m|f", at: at(100)), "the relay's answer after the return is still the cancel's")
        XCTAssertEqual(dog.restartsDue(at: at(100)), ["m|f"], "the first replacement is made at once")
        // A replacement owed at resign is made on return, not dropped.
        flow(dog, "m|g", rate: 36 * KB, from: 100, to: 120)
        XCTAssertEqual(dog.decisions(at: at(120)).map(\.attempt), [1])
        dog.cancelled("m|g", at: at(120))
        XCTAssertEqual(dog.restartsDue(at: at(120)), ["m|g"])
        flow(dog, "m|g", rate: 36 * KB, from: 120, to: 140, start: 36 * KB * 20)
        XCTAssertEqual(dog.decisions(at: at(140)).map(\.attempt), [2])
        dog.cancelled("m|g", at: at(140))
        dog.resigned(at: at(141))
        XCTAssertTrue(dog.restarting("m|g"))
        XCTAssertEqual(dog.restartsDue(at: at(160)), [], "due at 155, but nothing is made while the app is away")
        XCTAssertEqual(dog.probe([:], at: at(200)), [])
        XCTAssertEqual(dog.restartsDue(at: at(200)), ["m|g"], "owed at the resign, made on the first tick after the return")
    }

    func testNothingIsSampledOrJudgedWhileTheAppIsAway() {
        let dog = DownloadWatchdog()
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 10)
        dog.resigned(at: at(10))
        dog.observe("m|f", bytes: 36 * KB * 15, at: at(15))
        XCTAssertEqual(dog.kept("m|f"), 0, "a sample after the resign is refused until the probe")
        XCTAssertEqual(dog.decisions(at: at(40)), [], "no judgement while away, whatever a late tick asks")
        XCTAssertEqual(dog.probe(["m|f": 36 * KB * 10 + 36 * KB * 30], at: at(40)).map(\.key), ["m|f"])
        dog.forget("m|f")
        dog.observe("m|g", bytes: 0, at: at(41))
        XCTAssertEqual(dog.kept("m|g"), 1, "after the probe, samples are taken again")
    }

    func testTheMarksNameTheModelThePathBytesAndACountAndNothingElse() {
        XCTAssertEqual(DownloadWatchdog.slowMark(id: "parakeet-tdt-0.6b-v2", path: "Encoder.mlmodelc/weights/weight.bin", rate: 36864, attempt: 2),
                       "download.slow parakeet-tdt-0.6b-v2 Encoder.mlmodelc/weights/weight.bin rate=36864 attempt=2")
        XCTAssertEqual(DownloadWatchdog.restartedMark(id: "m", path: "p", at: 1234, resumed: true), "download.restarted m p at=1234 resumed=1")
        XCTAssertEqual(DownloadWatchdog.restartedMark(id: "m", path: "p", at: 0, resumed: false), "download.restarted m p at=0 resumed=0")
        XCTAssertEqual(DownloadWatchdog.resumedMark(id: "m", path: "p", from: 99), "download.resumedAt m p from=99")
        for mark in [DownloadWatchdog.slowMark(id: "m", path: "p", rate: 1, attempt: 1),
                     DownloadWatchdog.restartedMark(id: "m", path: "p", at: 1, resumed: true)] {
            XCTAssertFalse(mark.contains("http"), "no URL in a mark")
        }
    }

    func testTheConstantsAreTheDocumentsOnes() {
        XCTAssertEqual(DownloadWatchdog.floor, 256 * 1024)
        XCTAssertEqual(DownloadWatchdog.share, 10)
        XCTAssertEqual(DownloadWatchdog.window, .seconds(20))
        XCTAssertEqual(DownloadWatchdog.tick, .seconds(5))
        XCTAssertEqual(DownloadWatchdog.backoff, [.zero, .seconds(15), .seconds(30), .seconds(60)])
        XCTAssertEqual(DownloadWatchdog.cooldown, .seconds(300))
    }
}
