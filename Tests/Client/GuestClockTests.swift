import Foundation
import UIKit
@testable import Topo
import XCTest

/// Cues the test makes.
private final class FakeZoneChanges: ZoneChanges, @unchecked Sendable {
    private let lock = NSLock()
    private var changed: (@Sendable () -> Void)?
    private var starts = 0

    var started: Int { lock.withLock { starts } }
    func start(_ changed: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.changed = changed
            starts += 1
        }
    }
    func cancel() {}
    func change() { lock.withLock { changed }?() }
}

/// The phone's zone, every zone written in order, and whether the next write fails.
private final class Zones: @unchecked Sendable {
    private let lock = NSLock()
    private var now: String
    private var writes: [String] = []
    private var failing = false

    init(_ now: String) { self.now = now }
    func set(_ zone: String) { lock.withLock { now = zone } }
    func fail(_ fails: Bool) { lock.withLock { failing = fails } }
    func current() -> String { lock.withLock { now } }
    func record(_ zone: String) throws {
        try lock.withLock {
            writes.append(zone)
            if failing { throw CocoaError(.fileWriteUnknown) }
        }
    }
    var written: [String] { lock.withLock { writes } }
}

@MainActor
final class GuestClockTests: XCTestCase {
    private func waitFor(_ count: Int, _ zones: Zones) async {
        for _ in 0..<200 where zones.written.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The first write is made before `start` answers; every cue writes the zone the phone is in
    /// then, the same zone again included, since a command in the guest may have relinked it.
    func testEveryCueWritesThePhonesZoneThen() async {
        let changes = FakeZoneChanges()
        let zones = Zones("America/Los_Angeles")
        let clock = GuestClock(changes: changes, zone: zones.current, write: zones.record)
        await clock.start()
        XCTAssertEqual(zones.written, ["America/Los_Angeles"])

        changes.change()
        await waitFor(2, zones)
        XCTAssertEqual(zones.written, ["America/Los_Angeles", "America/Los_Angeles"], "an unchanged zone was not written again")

        zones.set("Europe/London")
        changes.change()
        await waitFor(3, zones)
        XCTAssertEqual(zones.written.last, "Europe/London")
    }

    /// A write that failed leaves nothing to skip: the next cue writes again.
    func testAFailedWriteIsTriedAgainAtTheNextCue() async {
        let changes = FakeZoneChanges()
        let zones = Zones("Asia/Tokyo")
        zones.fail(true)
        let clock = GuestClock(changes: changes, zone: zones.current, write: zones.record)
        await clock.start()
        XCTAssertEqual(zones.written, ["Asia/Tokyo"])

        zones.fail(false)
        changes.change()
        await waitFor(2, zones)
        XCTAssertEqual(zones.written, ["Asia/Tokyo", "Asia/Tokyo"])
    }

    /// The clock listens before its first write: a zone change that lands while that write runs is
    /// a cue after it, and the new zone is written.
    func testAChangeDuringTheFirstWriteIsNotLost() async {
        let changes = FakeZoneChanges()
        let zones = Zones("America/Los_Angeles")
        let clock = GuestClock(changes: changes, zone: zones.current, write: { zone in
            try zones.record(zone)
            if zones.written.count == 1 {
                zones.set("Europe/London")
                changes.change()
            }
        })
        await clock.start()
        await waitFor(2, zones)
        XCTAssertEqual(zones.written, ["America/Los_Angeles", "Europe/London"], "the change during the first write was lost")
    }

    /// A second start writes nothing more and listens to nothing more.
    func testStartingTwiceIsStartingOnce() async {
        let changes = FakeZoneChanges()
        let zones = Zones("Europe/London")
        let clock = GuestClock(changes: changes, zone: zones.current, write: zones.record)
        await clock.start()
        await clock.start()
        XCTAssertEqual(zones.written.count, 1)
        XCTAssertEqual(changes.started, 1, "a second start listened again")
    }

    /// Writes run one after another: a cue while a write is still going waits for it.
    func testWritesNeverOverlap() async {
        final class Writer: @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var most = 0
            var done = 0
            func write(_ zone: String) async {
                lock.withLock { running += 1; most = max(most, running) }
                try? await Task.sleep(for: .milliseconds(50))
                lock.withLock { running -= 1; done += 1 }
            }
        }
        final class Moving: @unchecked Sendable {
            let lock = NSLock()
            var reads = 0
            // A zone that has moved again by every read, so no write is skipped.
            func next() -> String { lock.withLock { reads += 1; return "Etc/GMT-\(reads)" } }
        }
        let writer = Writer()
        let moving = Moving()
        let clock = GuestClock(changes: FakeZoneChanges(), zone: moving.next, write: writer.write)
        let tasks = (0..<3).map { _ in clock.refresh() }
        for task in tasks { await task.value }
        XCTAssertEqual(writer.lock.withLock { writer.most }, 1, "two writes ran at once")
        XCTAssertEqual(writer.lock.withLock { writer.done }, 3)
    }

    /// The phone's own cues: a system zone change and a foreground each call back.
    func testTheSystemZoneChangeAndAForegroundCallBack() async {
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let count = Count()
        let changes = SystemZoneChanges()
        changes.start { count.lock.withLock { count.calls += 1 } }
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(count.lock.withLock { count.calls }, 1, "the zone change did not call back")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(count.lock.withLock { count.calls }, 2, "the foreground did not call back")
        changes.cancel()
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(count.lock.withLock { count.calls }, 2, "a cancelled listener still called back")
    }
}
