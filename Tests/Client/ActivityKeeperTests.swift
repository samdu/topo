import XCTest

@testable import Topo

/// Review Focus 6: the keeper's decisions against a fake host and a clock it moves — a changed
/// tracker is an update, an unchanged one nothing, an ended one ends the activity once, a failed
/// fetch changes nothing, `until` ends it, and a resume ends what is past its until.
@MainActor
final class ActivityKeeperTests: XCTestCase {
    private var host: FakeActivityHost!
    private var clock: FakeClock!

    override func setUp() {
        host = FakeActivityHost()
        clock = FakeClock()
    }

    private func keeper(_ fetcher: FakeTrackerFetcher) -> ActivityKeeper {
        ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date })
    }

    private func start(poll: Bool = true, until: Date? = nil) throws -> String {
        let tracker = try XCTUnwrap(ProgressTracker.read(Data(TrackerFixtures.wiki.utf8)).tracker)
        let attributes = TopoActivityAttributes(slot: "job", poll: poll ? URL(string: "https://h/progress/x") : nil, started: clock.date)
        return try host.start(attributes, ActivityNotice(state: ActivityState(card: TrackerCard(tracker), until: until), stale: nil, relevance: nil))
    }

    /// Lets the keeper's tasks reach their next sleep.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func tick(_ seconds: TimeInterval = 20) async {
        await settle()
        clock.advance(seconds)
        await settle()
    }

    func testAChangedTrackerIsAnUpdateAndAnUnchangedOneNothing() async throws {
        let moved = TrackerFixtures.wiki.replacingOccurrences(of: #""label": "Download", "state": "running""#, with: #""label": "Download", "state": "done""#)
        let fetcher = FakeTrackerFetcher([TrackerFixtures.wiki, moved, moved])
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick()
        XCTAssertEqual(host.updates, 0, "the same card is no update")
        await tick()
        XCTAssertEqual(host.updates, 1)
        guard case .update(let updated, let state, let stale) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(updated, id)
        XCTAssertEqual(state.card?.steps[1].state, .done)
        XCTAssertEqual(stale, clock.date.addingTimeInterval(ActivityKeeper.staleAfter))
        await tick()
        XCTAssertEqual(host.updates, 1, "unchanged again")
        XCTAssertEqual(fetcher.fetched.count, 3)
        keeper.forget(id)
    }

    func testEndedTrackerEndsOnce() async throws {
        let done = TrackerFixtures.tracker(steps: [("a", "done"), ("b", "done")], current: 1, state: "done", ended: true)
        let fetcher = FakeTrackerFetcher([done, done, done])
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick()
        XCTAssertEqual(host.ends.count, 1)
        guard case .end(let ended, let state?, .standard) = host.ends[0] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(ended, id)
        XCTAssertEqual(state.card?.state, .done)
        await tick()
        await tick()
        XCTAssertEqual(host.ends.count, 1, "the poll stopped with the activity")
        XCTAssertEqual(fetcher.fetched.count, 1)
    }

    func testAFailedFetchChangesNothing() async throws {
        let fetcher = FakeTrackerFetcher([nil, "not json", #"{"kind": "decision"}"#])
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick(); await tick(); await tick()
        XCTAssertEqual(host.updates, 0)
        XCTAssertEqual(host.ends.count, 0)
        XCTAssertEqual(fetcher.fetched.count, 3, "and the poll goes on")
        keeper.forget(id)
    }

    func testAnActivityEndedElsewhereStopsItsPoll() async throws {
        let fetcher = FakeTrackerFetcher([TrackerFixtures.wiki, TrackerFixtures.wiki])
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await host.end(id, nil, dismissal: .now)
        await tick()
        XCTAssertEqual(fetcher.fetched.count, 0, "nothing is fetched for an ended activity")
        XCTAssertEqual(clock.sleepers, 0)
    }

    func testUntilEndsTheActivityWhileTopoRuns() async throws {
        let keeper = keeper(FakeTrackerFetcher([]))
        let id = try start(poll: false, until: clock.date.addingTimeInterval(120))
        keeper.keep(id)
        await tick(119)
        XCTAssertEqual(host.ends.count, 0)
        await tick(1)
        XCTAssertEqual(host.ends.count, 1)
        guard case .end(id, nil, .now) = host.ends[0] else { return XCTFail("\(host.ends)") }
        // Kept again with a later until: the earlier end is cancelled, the later stands.
        let second = try start(poll: false, until: clock.date.addingTimeInterval(60))
        keeper.keep(second)
        host.records[host.records.firstIndex { $0.id == second }!].state.until = clock.date.addingTimeInterval(600)
        keeper.keep(second)
        await tick(60)
        XCTAssertEqual(host.ends.count, 1, "the moved until did not end it at the old time")
        await tick(540)
        XCTAssertEqual(host.ends.count, 2)
    }

    func testResumeEndsWhatIsPastItsUntilAndKeepsTheRest() async throws {
        let fetcher = FakeTrackerFetcher([TrackerFixtures.wiki])
        let keeper = keeper(fetcher)
        let past = try start(poll: false, until: clock.date.addingTimeInterval(-1))
        host.records[0].attributes = TopoActivityAttributes(slot: "old", poll: nil, started: clock.date)
        let live = try start(until: clock.date.addingTimeInterval(3600))
        await keeper.resume()
        XCTAssertEqual(host.ends.count, 1)
        guard case .end(past, nil, .now) = host.ends[0] else { return XCTFail("\(host.ends)") }
        await tick()
        XCTAssertEqual(fetcher.fetched.count, 1, "the live one is polled again")
        keeper.forget(live)
    }

    func testEndAllEndsEveryRunningActivityNow() async throws {
        let keeper = keeper(FakeTrackerFetcher([]))
        let a = try start()
        host.records[0].attributes = TopoActivityAttributes(slot: "a", poll: nil, started: clock.date)
        let b = try start(until: clock.date.addingTimeInterval(60))
        keeper.keep(a)
        keeper.keep(b)
        await host.end(a, nil, dismissal: .standard)
        await keeper.endAll()
        XCTAssertEqual(host.ends.count, 2, "the one already ended is not ended again")
        guard case .end(b, nil, .now) = host.ends[1] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(clock.sleepers, 0, "no task survives")
    }

    func testStaleDate() {
        let keeper = keeper(FakeTrackerFetcher([]))
        let until = clock.date.addingTimeInterval(30)
        XCTAssertNil(keeper.staleDate(until: nil, polled: false))
        XCTAssertEqual(keeper.staleDate(until: until, polled: false), until)
        XCTAssertEqual(keeper.staleDate(until: nil, polled: true), clock.date.addingTimeInterval(60))
        XCTAssertEqual(keeper.staleDate(until: until, polled: true), until, "the earlier of the two")
    }
}
