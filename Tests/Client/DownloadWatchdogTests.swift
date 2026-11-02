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

    func testAStalledTaskIsCancelledOnceAWindowOfSamplesExistsAndNotBefore() {
        let dog = DownloadWatchdog()
        flow(dog, "m|f", rate: 36 * KB, from: 0, to: 19)
        XCTAssertEqual(dog.decisions(at: at(19)), [], "19 s of samples is less than a window")
        XCTAssertTrue(dog.active)
        let cancels = dog.decisions(at: at(20))
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels[0].key, "m|f")
        XCTAssertEqual(cancels[0].attempt, 1)
        XCTAssertLessThanOrEqual(abs(cancels[0].rate - 36 * KB), KB)
        XCTAssertTrue(dog.restarting("m|f"), "between its cancel and its replacement the key is restarting")
        XCTAssertEqual(dog.decisions(at: at(25)), [], "a cancel is recorded as it is decided, not when the relay answers")
    }

    func testAFastTaskAndOneWithNoFirstByteAreLeftAlone() {
        let dog = DownloadWatchdog()
        flow(dog, "m|fast", rate: 2 * MB, from: 0, to: 60)
        XCTAssertEqual(dog.decisions(at: at(60)), [])
        XCTAssertEqual(dog.decisions(at: at(60)), [], "a task with no samples is not judged")
        XCTAssertFalse(dog.restarting("m|none"))
    }

    func testSilenceAfterAFirstByteIsSlow() {
        let dog = DownloadWatchdog()
        dog.observe("m|f", bytes: 5 * MB, at: at(0))
        XCTAssertEqual(dog.decisions(at: at(20)).map(\.rate), [0], "no bytes since the anchor is a rate of zero")
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
        XCTAssertEqual(dog.restartsDue(at: at(Double(later + 20 + 59))), [])
        XCTAssertEqual(dog.restartsDue(at: at(Double(later + 20 + 60))), ["m|f"], "the last backoff holds past the fourth")
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
        // A restart owed at resign is the next foreground start()'s, not the probe's.
        flow(dog, "m|g", rate: 36 * KB, from: 100, to: 120)
        XCTAssertEqual(dog.decisions(at: at(120)).count, 1)
        dog.cancelled("m|g", at: at(120))
        dog.resigned(at: at(121))
        XCTAssertFalse(dog.restarting("m|g"))
        XCTAssertEqual(dog.probe([:], at: at(200)), [])
        XCTAssertEqual(dog.restartsDue(at: at(300)), [])
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
