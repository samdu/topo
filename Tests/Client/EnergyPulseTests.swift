import XCTest

@testable import Topo

@MainActor
final class EnergyPulseTests: XCTestCase {
    /// The emulator names a guest process's host thread `<command>-<pid>`, and the command is
    /// the person's; the thread is counted as the guest's.
    func testAGuestThreadIsKnownByItsPidSuffix() {
        XCTAssertTrue(EnergyPulse.isGuestThread("krista-med-1234"))
        XCTAssertTrue(EnergyPulse.isGuestThread("sh-7"))
        XCTAssertFalse(EnergyPulse.isGuestThread("com.apple.NSURLSession-work"))
        XCTAssertFalse(EnergyPulse.isGuestThread("JSCWarmUp"))
        XCTAssertFalse(EnergyPulse.isGuestThread("-12"))
        XCTAssertFalse(EnergyPulse.isGuestThread("claude-"))
        XCTAssertFalse(EnergyPulse.isGuestThread(""))
    }

    /// The newest payloads of a kind stay, by the seconds in the name, and the other kind's
    /// files are not what makes room.
    func testPruningKeepsTheNewestOfEachKind() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("energy-pulse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = (1...16).map { "metrics-\(1_000_000 + $0 * 86_400).json" }
            + ["diagnostics-1000100.json", "diagnostics-2500000.json", "metrics-900000.json"]
        for name in names {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }

        EnergyPulse.prune(dir, prefix: "metrics", keep: 14)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left.filter { $0.hasPrefix("metrics-") }.count, 14)
        XCTAssertFalse(left.contains("metrics-900000.json"))
        XCTAssertFalse(left.contains("metrics-1086400.json"))
        XCTAssertFalse(left.contains("metrics-1172800.json"))
        XCTAssertTrue(left.contains("metrics-2382400.json"))
        XCTAssertTrue(left.contains("diagnostics-1000100.json"))
        XCTAssertTrue(left.contains("diagnostics-2500000.json"))
    }

    /// A hundred guest threads at 0.04 s each are four seconds of the guest's, not nothing: the
    /// threads are summed under their name before a group is left out.
    func testThreadsAreSummedByNameBeforeTheFloor() {
        var after: [UInt64: (name: String, cpu: Double)] = [:]
        for id in 1...100 { after[UInt64(id)] = ("guest", 0.04) }
        for id in 101...150 { after[UInt64(id)] = ("unnamed", 0.04) }
        after[200] = ("com.apple.lonely", 0.04)
        let line = EnergyPulse.breakdown(process: 6.04, before: [:], after: after)
        XCTAssertEqual(line, "guest 4.00s, unnamed 2.00s")
    }

    /// A thread that ended inside the interval is no longer listed; what it spent is the process's
    /// time the survivors do not account for, and is said as such.
    func testCPUOfThreadsThatEndedIsUnattributed() {
        let before: [UInt64: Double] = [1: 1.0, 2: 5.0]
        let after: [UInt64: (name: String, cpu: Double)] = [1: ("main", 2.0)]
        let line = EnergyPulse.breakdown(process: 11.0, before: before, after: after)
        XCTAssertEqual(line, "main 1.00s, unattributed 10.00s")
    }

    /// The thread baseline is taken with the process's: time a thread spent before it is in
    /// neither mark, and a thread started inside the interval counts from nothing.
    func testABaselineKeepsTimeBeforeItOut() {
        let before: [UInt64: Double] = [1: 2.0]
        let after: [UInt64: (name: String, cpu: Double)] = [1: ("main", 3.0), 9: ("worker", 0.5)]
        XCTAssertEqual(EnergyPulse.breakdown(process: 1.5, before: before, after: after),
                       "main 1.00s, worker 0.50s")
        XCTAssertEqual(EnergyPulse.breakdown(process: 3.5, before: [:], after: after),
                       "main 3.00s, worker 0.50s")
    }

    /// A rate is over the continuous clock's interval, which a change of the wall clock does not
    /// move.
    func testAnIntervalIsReadInSeconds() {
        XCTAssertEqual(EnergyPulse.interval(.seconds(60)), 60, accuracy: 1e-9)
        XCTAssertEqual(EnergyPulse.interval(.milliseconds(1500)), 1.5, accuracy: 1e-9)
    }

    /// A sample the kernel would not give is no baseline: the next one is taken as one, so a
    /// surviving thread's lifetime is never counted as one interval's.
    func testAFailedSampleIsFollowedByABaselineNotALifetime() {
        let first = EnergyPulse.advance(process: 0, before: nil, sample: .init(threads: [1: ("worker", 100)]))
        XCTAssertNil(first.line)
        XCTAssertEqual(first.next, [1: 100])
        let failed = EnergyPulse.advance(process: 1, before: first.next, sample: nil)
        XCTAssertNil(failed.line)
        XCTAssertNil(failed.next)
        let rebased = EnergyPulse.advance(process: 1, before: failed.next, sample: .init(threads: [1: ("worker", 102)]))
        XCTAssertNil(rebased.line)
        XCTAssertEqual(rebased.next, [1: 102])
        let after = EnergyPulse.advance(process: 1, before: rebased.next, sample: .init(threads: [1: ("worker", 103)]))
        XCTAssertEqual(after.line, "worker 1.00s")
    }

    /// A thread that gave its id and no times keeps its last baseline, and its interval's time is
    /// unattributed; one with no baseline to keep makes the sample no baseline.
    func testAThreadThatGaveNoTimesKeepsItsBaseline() {
        let sample = EnergyPulse.ThreadSample(threads: [1: ("main", 3)], unread: [2])
        let kept = EnergyPulse.advance(process: 3, before: [1: 2, 2: 50], sample: sample)
        XCTAssertEqual(kept.line, "main 1.00s, unattributed 2.00s")
        XCTAssertEqual(kept.next, [1: 3, 2: 50])
        let lost = EnergyPulse.advance(process: 3, before: [1: 2], sample: sample)
        XCTAssertNil(lost.line)
        XCTAssertNil(lost.next)
    }

    /// Past the busiest eight groups the rest are summed as `other`, not dropped.
    func testGroupsPastTheEighthAreOther() {
        var after: [UInt64: (name: String, cpu: Double)] = [:]
        for id in 1...9 { after[UInt64(id)] = ("t\(id)", Double(id)) }
        let line = EnergyPulse.breakdown(process: 45, before: [:], after: after)
        XCTAssertEqual(line, "t9 9.00s, t8 8.00s, t7 7.00s, t6 6.00s, t5 5.00s, t4 4.00s, t3 3.00s, t2 2.00s, other 1.00s")
    }
}
