import XCTest

@testable import Topo

/// Review Focus 6: the keeper's decisions against a fake host and a clock it moves — every
/// answered fetch an update that moves the stale date, an ended tracker ending the activity once,
/// a failed fetch changing nothing, `until` ending it, a resume ending what is past its until,
/// and what lands during a fetch (an end, an update, a sign-out) read again after it.
@MainActor
final class ActivityKeeperTests: XCTestCase {
    private var host: FakeActivityHost!
    private var clock: FakeClock!

    override func setUp() {
        host = FakeActivityHost()
        clock = FakeClock()
    }

    private func keeper(_ fetcher: TrackerFetcher) -> ActivityKeeper {
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

    func testEveryAnsweredFetchMovesTheStaleDateAndAChangedTrackerTheCard() async throws {
        let moved = TrackerFixtures.wiki.replacingOccurrences(of: #""label": "Download", "state": "running""#, with: #""label": "Download", "state": "done""#)
        let fetcher = FakeTrackerFetcher([TrackerFixtures.wiki, moved, moved])
        let keeper = keeper(fetcher)
        let id = try start()
        let before = host.records[0].state.card
        keeper.keep(id)
        await tick()
        XCTAssertEqual(host.updates, 1, "the same card still moves the stale date: a long step is not a tracker gone quiet")
        guard case .update(_, let same, let stale1) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(same.card, before)
        XCTAssertEqual(stale1, clock.date.addingTimeInterval(ActivityKeeper.staleAfter))
        await tick()
        XCTAssertEqual(host.updates, 2)
        guard case .update(let updated, let state, let stale) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(updated, id)
        XCTAssertEqual(state.card?.steps[1].state, .done)
        XCTAssertEqual(stale, clock.date.addingTimeInterval(ActivityKeeper.staleAfter))
        await tick()
        XCTAssertEqual(host.updates, 3)
        XCTAssertEqual(fetcher.fetched.count, 3)
        keeper.forget(id)
    }

    func testAPollDoesNotEndWhatThePersonEndedDuringTheFetch() async throws {
        let fetcher = GatedTrackerFetcher()
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick()
        XCTAssertEqual(fetcher.pending, 1)
        await host.end(id, nil, dismissal: .now)
        fetcher.release(TrackerFixtures.tracker(steps: [("a", "done")], state: "done", ended: true))
        await settle()
        XCTAssertEqual(host.ends.count, 1, "the person's end, and no second from the poll")
        XCTAssertEqual(keeper.tasks, 0)
    }

    func testAPollDoesNotRevertAnUpdateLandedDuringTheFetch() async throws {
        let fetcher = GatedTrackerFetcher()
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick()
        XCTAssertEqual(fetcher.pending, 1)
        // The tool's update lands while the fetch is out: a layout, a later until, a relevance.
        var updated = host.records[0].state
        updated.layout = ActivityLayout(regions: [.islandMinimal: .divider], tint: nil).text
        updated.until = clock.date.addingTimeInterval(600)
        updated.relevance = 90
        await host.update(id, ActivityNotice(state: updated, stale: nil, relevance: 90))
        keeper.keep(id)
        let moved = TrackerFixtures.wiki.replacingOccurrences(of: #""label": "Download", "state": "running""#, with: #""label": "Download", "state": "done""#)
        fetcher.release(moved)
        await settle()
        guard case .update(_, let state, _) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(state.layout, updated.layout, "the layout the update set stands")
        XCTAssertEqual(state.until, updated.until)
        XCTAssertEqual(state.relevance, 90)
        XCTAssertEqual(state.card?.steps[1].state, .done, "with the card the poll fetched")
        keeper.forget(id)
    }

    func testAPollLeavesARoundToTheNextWhenTheToolsUpdateIsStillInTheHost() async throws {
        let fetcher = GatedTrackerFetcher()
        let keeper = keeper(fetcher)
        let id = try start()
        keeper.keep(id)
        await tick()
        XCTAssertEqual(fetcher.pending, 1)
        // The tool's update is sent and not yet applied by the host when the poll's fetch answers.
        let gate = HostGate()
        host.wait = { await gate.wait() }
        var updated = host.records[0].state
        updated.relevance = 90
        keeper.touch(id)
        let sent = Task { [host] in await host!.update(id, ActivityNotice(state: updated, stale: nil, relevance: 90)) }
        await settle()
        fetcher.release(TrackerFixtures.wiki)
        await settle()
        XCTAssertEqual(host.updates, 1, "the poll wrote nothing over the update on its way")
        host.wait = nil
        gate.openUp()
        _ = await sent.value
        await tick()
        fetcher.release(TrackerFixtures.wiki)
        await settle()
        guard case .update(_, let state, _) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(state.relevance, 90, "the next round reads what the host holds")
        keeper.forget(id)
    }

    func testASignOutDuringTheFetchUpdatesNothingAndLeavesNoTask() async throws {
        let fetcher = GatedTrackerFetcher()
        let keeper = keeper(fetcher)
        let id = try start(until: clock.date.addingTimeInterval(600))
        keeper.keep(id)
        await tick()
        XCTAssertEqual(fetcher.pending, 1)
        await keeper.endAll()
        fetcher.release(TrackerFixtures.wiki)
        await settle()
        XCTAssertEqual(host.updates, 0)
        XCTAssertEqual(host.ends.count, 1)
        XCTAssertEqual(keeper.tasks, 0)
        await tick(600)
        XCTAssertEqual(host.ends.count, 1, "nothing ends it a second time at its until")
    }

    func testUntilDoesNotEndWhatThePersonEnded() async throws {
        let keeper = keeper(FakeTrackerFetcher([]))
        let id = try start(poll: false, until: clock.date.addingTimeInterval(120))
        keeper.keep(id)
        await host.end(id, nil, dismissal: .standard)
        await tick(120)
        XCTAssertEqual(host.ends.count, 1, "the person's end alone")
        XCTAssertEqual(keeper.tasks, 0)
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

    func testEndAllTakesEveryActivityOffTheLockScreenNow() async throws {
        let keeper = keeper(FakeTrackerFetcher([]))
        let a = try start()
        host.records[0].attributes = TopoActivityAttributes(slot: "a", poll: nil, started: clock.date)
        let b = try start(until: clock.date.addingTimeInterval(60))
        keeper.keep(a)
        keeper.keep(b)
        await settle()
        XCTAssertEqual(keeper.tasks, 2)
        await host.end(a, nil, dismissal: .standard)
        await keeper.endAll()
        XCTAssertEqual(host.ends.count, 3, "the one ended with the default dismissal is still on the lock screen, and is taken off")
        guard case .end(a, nil, .now) = host.ends[1], case .end(b, nil, .now) = host.ends[2] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(keeper.tasks, 0, "no task survives")
        await tick(600)
        XCTAssertEqual(host.calls.count, 5, "and nothing acts after")
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
