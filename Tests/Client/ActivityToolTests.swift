import TopoTools
import XCTest

@testable import Topo

/// Review Focus 4, 5 and 8: `topo activity`'s calls against a fake ActivityKit — one activity a
/// slot, the system's refusals said with their reason, and every activity ended with the login.
@MainActor
final class ActivityToolTests: XCTestCase {
    private var host: FakeActivityHost!
    private var clock: FakeClock!
    private var keeper: ActivityKeeper!
    private var fetcher: TrackerFetcher!
    private var login: LoginLife!

    private var bare: ActivityTool {
        ActivityTool(host: { [host] in host! }, keeper: { [keeper] in keeper! }, fetcher: fetcher, now: { [clock] in clock!.date })
    }

    /// The tool as a launch's tool service hands it a call: every call carries the login standing
    /// when the tool was taken, as a call carries the one its launch was started under.
    private var tool: Launched { Launched(tool: bare, login: login.epoch) }

    override func setUp() {
        host = FakeActivityHost()
        clock = FakeClock()
        fetcher = FakeTrackerFetcher([])
        login = LoginLife()
        keeper = ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date },
                                login: login)
    }

    private let timer = #"{"version": 1, "until": "2026-11-02T06:00:00Z", "families": {"lockScreen": {"kind": "text", "text": "Tea", "date": "2026-11-02T06:00:00Z", "dateStyle": "timer"}}}"#

    func testStartsAndListsATracker() async throws {
        let reply = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki)}"#])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(reply.text, "started A1 for slot job\n")
        XCTAssertEqual(host.starts, 1)
        guard case .start(let slot, let poll, let state, let stale) = host.calls[0] else { return XCTFail() }
        XCTAssertEqual(slot, "job")
        XCTAssertNil(poll)
        XCTAssertEqual(state.card?.title, "macOS update on buddybox")
        XCTAssertNil(stale, "no until and no poll: nothing goes stale")
        let listed = await tool.run([])
        XCTAssertTrue(listed.text.contains("activity: A1 | slot job | running"), listed.text)
        XCTAssertTrue(listed.text.contains("tracker: macOS update on buddybox, 1 of 3 done, running, at Download"), listed.text)
    }

    func testStartOnRunningSlotRefused() async throws {
        _ = await tool.run(["start", "job", timer])
        let again = await tool.run(["start", "job", timer])
        XCTAssertEqual(again.status, ToolReply.failed)
        XCTAssertTrue(again.text.contains("running as A1"), again.text)
        XCTAssertEqual(host.starts, 1)
        // Ended, the slot is free again.
        _ = await tool.run(["end", "A1"])
        let third = await tool.run(["start", "job", timer])
        XCTAssertEqual(third.status, ToolReply.ok, third.text)
    }

    func testStartRefusedByTheSystemSaysWhy() async throws {
        host.refusal = .notOnScreen
        let reply = await tool.run(["start", "job", timer])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertTrue(reply.text.contains("not on the screen"), reply.text)
        host.refusal = .tooMany
        let reply1 = await tool.run(["start", "job", timer])
        XCTAssertTrue(reply1.text.contains("as many"))
        host.refusal = .other("boom")
        let reply2 = await tool.run(["start", "job", timer])
        XCTAssertTrue(reply2.text.contains("boom"))
        host.refusal = .disabled
        let reply3 = await tool.run(["start", "job", timer])
        XCTAssertEqual(reply3.status, ToolReply.denied)
        XCTAssertTrue(host.running().isEmpty)
    }

    func testDisabledIsDenied() async {
        host.enabled = false
        let reply = await tool.run(["start", "job", timer])
        XCTAssertEqual(reply.status, ToolReply.denied)
        XCTAssertTrue(reply.text.contains("Settings"), reply.text)
        XCTAssertEqual(host.starts, 0)
    }

    func testPartRefusedIsSixAndStarts() async {
        let reply = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "tint": "mauve"}"#])
        XCTAssertEqual(reply.status, ToolReply.refused)
        XCTAssertTrue(reply.text.hasPrefix("started A1 for slot job\nnote: tint "), reply.text)
        XCTAssertEqual(host.starts, 1)
    }

    func testUnreadableIsTwoAndStartsNothing() async {
        for json in ["nope", #"{"tint": "primary"}"#] {
            let reply = await tool.run(["start", "job", json])
            XCTAssertEqual(reply.status, ToolReply.usage, reply.text)
        }
        let reply4 = await tool.run(["start", "Bad Slot", timer])
        XCTAssertEqual(reply4.status, ToolReply.usage)
        XCTAssertEqual(host.starts, 0)
    }

    func testPollFetchesTheTrackerAtTheStart() async throws {
        fetcher = FakeTrackerFetcher([TrackerFixtures.wiki])
        let reply = await tool.run(["start", "job", #"{"poll": "https://pane.example.ts.net/decisions/progress/b36e250e"}"#])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual((fetcher as? FakeTrackerFetcher)?.fetched.map(\.absoluteString), ["https://pane.example.ts.net/decisions/progress/b36e250e"])
        guard case .start(_, let poll, let state, let stale) = host.calls[0] else { return XCTFail() }
        XCTAssertEqual(poll?.host, "pane.example.ts.net")
        XCTAssertEqual(state.card?.title, "macOS update on buddybox")
        XCTAssertEqual(stale, clock.date.addingTimeInterval(ActivityKeeper.staleAfter), "a polled activity goes stale a minute past its update")
        let reply5 = await tool.run([])
        XCTAssertTrue(reply5.text.contains("polled from pane.example.ts.net"))
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testASignOutDuringTheStartsFetchStartsNothing() async throws {
        let gate = GatedTrackerFetcher()
        fetcher = gate
        let tool = self.tool
        let started = Task { await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#]) }
        await SigningOut.midFlight(login, reached: { gate.pending == 1 }) { gate.release(TrackerFixtures.wiki) }
        let reply = await started.value
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("login ended"), reply.text)
        XCTAssertEqual(host.starts, 0)
        XCTAssertEqual(keeper.tasks, 0)
        XCTAssertFalse(keeper.isReserved("job"), "the slot is free again")
    }

    func testAStartFromBeforeASignOutReleasesNoLaterStartsSlot() async throws {
        let gate = GatedTrackerFetcher()
        fetcher = gate
        let tool = self.tool
        let first = Task { await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#]) }
        await SigningOut.midFlight(login, reached: { gate.pending == 1 })
        // Signed in again: the second start is the next login's, by a launch of its own.
        login.began()
        let next = self.tool
        let second = Task { await next.run(["start", "job", #"{"poll": "https://h/progress/x"}"#]) }
        await settle()
        XCTAssertEqual(gate.pending, 2)
        gate.release(TrackerFixtures.wiki)
        let firstReply = await first.value
        XCTAssertEqual(firstReply.status, ToolReply.failed, firstReply.text)
        let third = await next.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        XCTAssertEqual(third.status, ToolReply.failed, "the second start still holds the slot")
        XCTAssertTrue(third.text.contains("is starting"), third.text)
        gate.release(TrackerFixtures.wiki)
        let secondReply = await second.value
        XCTAssertEqual(secondReply.status, ToolReply.ok, secondReply.text)
        XCTAssertEqual(host.starts, 1)
        keeper.forget("A1")
    }

    /// The phase leaving signed in on its own (`SignIn.refresh` finding the login gone) reaches
    /// the keeper too, through `DefaultSurface.follow`.
    func testALoginLostToARefreshEndsEveryActivity() async throws {
        _ = await tool.run(["start", "job", timer])
        let surface = DefaultSurface(store: { nil }, reloader: SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in },
                                                                               reloadEveryControl: {}, schedule: { _, _ in }),
                                     login: login)
        surface.follow(from: .signedIn, to: .idle, latest: nil)
        await login.tornDown()
        XCTAssertEqual(host.ends.count, 1)
        guard case .end("A1", nil, .now) = host.ends[0] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(keeper.tasks, 0)
    }

    /// A start received while the sign-out is under way (after its first step, the guest's tool
    /// call answered while the harness is waited on) whose fetch lands after the teardowns
    /// starts nothing and keeps nothing.
    func testAStartReceivedDuringASignOutStartsNothing() async throws {
        let gate = GatedTrackerFetcher()
        fetcher = gate
        login.moveEpoch()
        // From a launch made after the sign-out's first step, so it carries the moved epoch.
        let tool = self.tool
        let started = Task { await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#]) }
        await settle()
        XCTAssertEqual(gate.pending, 1)
        login.runTeardowns()
        await login.tornDown()
        gate.release(TrackerFixtures.wiki)
        let reply = await started.value
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(host.starts, 0, "an activity started after the sign-out's end")
        XCTAssertEqual(keeper.tasks, 0)
    }

    /// A start received once the login's teardowns have run, before the keeper's end has
    /// started or after it has finished, starts nothing and fetches nothing: no epoch is current
    /// until the next sign-in.
    func testAStartReceivedAfterTheTeardownsStartsNothing() async throws {
        let gate = GatedTrackerFetcher()
        fetcher = gate
        let tool = self.tool
        login.end()
        // Received before the keeper's end has started: refused as it is received.
        let reply = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("login has ended"), reply.text)
        XCTAssertEqual(gate.fetched.count, 0, "a start after the login's end fetched")
        await login.tornDown()
        XCTAssertEqual(host.starts, 0, "an activity started after the login's end")
        XCTAssertEqual(keeper.tasks, 0)
        // A start that awaits nothing is refused as it is received.
        let timed = await tool.run(["start", "tea", timer])
        XCTAssertEqual(timed.status, ToolReply.failed, timed.text)
        XCTAssertEqual(host.starts, 0, "an activity started after the login's end")
        XCTAssertFalse(keeper.isReserved("tea"))
    }

    /// A start carrying a login that has ended, received once the next login has an activity in
    /// the slot, is refused as the ended login's and says nothing of the next login's activity.
    func testAStartFromAnEndedLoginSaysNothingOfTheNextLoginsSlot() async throws {
        let ended = self.tool
        login.end()
        await login.tornDown()
        login.began()
        let next = await tool.run(["start", "job", timer])
        XCTAssertEqual(next.status, ToolReply.ok, next.text)
        let reply = await ended.run(["start", "job", timer])
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(reply.text, "topo: the login has ended; nothing started\n")
        XCTAssertEqual(host.starts, 1)
        keeper.forget("A1")
    }

    func testTwoStartsOfOneSlotMakeOneActivity() async throws {
        let gate = GatedTrackerFetcher()
        fetcher = gate
        let tool = self.tool
        let first = Task { await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#]) }
        await settle()
        XCTAssertEqual(gate.pending, 1)
        let second = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        XCTAssertEqual(second.status, ToolReply.failed, second.text)
        XCTAssertTrue(second.text.contains("is starting"), second.text)
        gate.release(TrackerFixtures.wiki)
        let reply = await first.value
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(host.starts, 1)
        XCTAssertEqual(gate.fetched.count, 1, "the refused start fetched nothing")
        XCTAssertFalse(keeper.isReserved("job"))
        keeper.forget("A1")
    }

    func testAnUpdateInFlightAcrossASignOutKeepsNothing() async throws {
        _ = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "until": "2026-11-02T06:00:00Z"}"#])
        let gate = HostGate()
        host.wait = { await gate.wait() }
        let tool = self.tool
        let update = Task { await tool.run(["update", "A1", #"{"relevance": 5}"#]) }
        await settle()
        XCTAssertEqual(gate.held, 1, "the update is in the host")
        host.wait = nil
        // The sign-out moves the epoch at once and then waits its turn behind the update.
        let keeper = self.keeper!
        let before = login.epoch
        login.moveEpoch()
        login.runTeardowns()
        await settle()
        XCTAssertFalse(before.isCurrent)
        XCTAssertTrue(host.ends.isEmpty, "the sign-out's end waits behind the update in the host")
        gate.openUp()
        _ = await update.value
        await login.tornDown()
        XCTAssertEqual(keeper.tasks, 0, "the update from before the sign-out kept nothing")
        let after = await tool.run(["update", "A1", #"{"relevance": 5}"#])
        XCTAssertEqual(after.status, ToolReply.failed, "ended is not running")
    }

    /// An update and an end that wait at the gate while a sign-out moves the epoch send nothing:
    /// the sign-out's own end is the only one, and the update's host call is the first update's.
    func testAnUpdateAndAnEndQueuedAcrossASignOutSendNothing() async throws {
        _ = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "until": "2026-11-02T06:00:00Z"}"#])
        let gate = HostGate()
        host.wait = { await gate.wait() }
        let tool = self.tool
        let first = Task { await tool.run(["update", "A1", #"{"relevance": 5}"#]) }
        await settle()
        XCTAssertEqual(gate.held, 1, "the first update is in the host")
        host.wait = nil
        let queued = Task { await tool.run(["update", "A1", #"{"relevance": 6}"#]) }
        let ended = Task { await tool.run(["end", "A1", #"{"relevance": 7}"#]) }
        await settle()
        let keeper = self.keeper!
        // The next login stands as the gate opens, so the queued calls are refused by the login they
        // carry, not by finding none current.
        await SigningOut.midFlight(login, reached: { gate.held == 1 }, release: { login.began(); gate.openUp() })
        _ = await first.value
        let update = await queued.value
        let end = await ended.value
        XCTAssertEqual(update.status, ToolReply.failed, update.text)
        XCTAssertTrue(update.text.contains("login ended"), update.text)
        XCTAssertEqual(end.status, ToolReply.failed, end.text)
        XCTAssertTrue(end.text.contains("login ended"), end.text)
        XCTAssertEqual(host.updates, 1, "\(host.calls)")
        XCTAssertEqual(host.ends.count, 1, "\(host.ends)")
        guard case .end("A1", nil, .now) = host.ends[0] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(keeper.tasks, 0)
    }

    func testOverBudgetDocumentIsRefusedWhole() async throws {
        let children = (0..<60).map { _ in #"{"kind": "text", "text": "\#(String(repeating: "w", count: 58))"}"# }.joined(separator: ",")
        let big = #"{"families": {"lockScreen": {"kind": "vstack", "children": [\#(children)]}}}"#
        let reply = await tool.run(["start", "job", big])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertTrue(reply.text.contains("nothing started"), reply.text)
        XCTAssertEqual(host.starts, 0)
        XCTAssertFalse(keeper.isReserved("job"))
        _ = await tool.run(["start", "job", timer])
        let update = await tool.run(["update", "A1", big])
        XCTAssertEqual(update.status, ToolReply.refused, update.text)
        XCTAssertTrue(update.text.contains("nothing changed"), update.text)
        XCTAssertEqual(host.updates, 0)
    }

    func testAPollOnAnUpdateIsNotedAndStands() async throws {
        _ = await tool.run(["start", "job", timer])
        let reply = await tool.run(["update", "A1", #"{"poll": "https://h/progress/x", "relevance": 5}"#])
        XCTAssertEqual(reply.status, ToolReply.refused, reply.text)
        XCTAssertTrue(reply.text.contains("poll is set at the start"), reply.text)
        XCTAssertEqual(host.updates, 1)
        XCTAssertNil(host.records[0].attributes.poll)
    }

    func testPollThatGivesNoTrackerStartsNothing() async {
        fetcher = FakeTrackerFetcher([nil])
        var reply = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertTrue(reply.text.contains("no tracker"), reply.text)
        fetcher = FakeTrackerFetcher([#"{"kind": "decision"}"#])
        reply = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertEqual(host.starts, 0)
    }

    /// A tracker given beside a poll does not skip the start's fetch. A fetch that
    /// fails starts nothing; one that answers is the tracker drawn, and the given one is noted
    /// as set aside.
    func testAPollIsFetchedAtTheStartEvenBesideATracker() async throws {
        fetcher = FakeTrackerFetcher([nil])
        let failed = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "poll": "https://h/progress/x"}"#])
        XCTAssertEqual(failed.status, ToolReply.failed, failed.text)
        XCTAssertEqual((fetcher as? FakeTrackerFetcher)?.fetched.count, 1)
        XCTAssertEqual(host.starts, 0)
        fetcher = FakeTrackerFetcher([TrackerFixtures.tracker(steps: [("a", "running")])])
        let started = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "poll": "https://h/progress/x"}"#])
        XCTAssertEqual(started.status, ToolReply.refused, started.text)
        XCTAssertTrue(started.text.contains(ActivityTool.trackerSetAside), started.text)
        guard case .start(_, _, let state, _) = host.calls.last else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(state.card?.title, "A tracker", "the polled tracker is drawn")
    }

    /// An end while the poll's end of a finished tracker is still in the host
    /// waits its turn, finds the activity ended, and sends no second end.
    func testAnEndWhileThePollsEndIsInTheHostSendsNoSecond() async throws {
        let done = TrackerFixtures.tracker(steps: [("a", "done")], state: "done", ended: true)
        fetcher = FakeTrackerFetcher([TrackerFixtures.wiki, done])
        keeper = ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date }, login: login)
        _ = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        let gate = HostGate()
        host.wait = { await gate.wait() }
        await settle()
        clock.advance(20)
        await settle()
        XCTAssertEqual(gate.held, 1, "the poll's end is in the host")
        let ended = Task { await tool.run(["end", "A1"]) }
        await settle()
        host.wait = nil
        gate.openUp()
        let reply = await ended.value
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(host.ends.count, 1, "\(host.ends)")
    }

    /// Through the tool, `topo activity update` while the poll's fetch is out and
    /// its own update is still in the host. The poll's round waits, finds the update counted and
    /// is left to the next, so the relevance the tool set stands.
    func testAToolUpdateInTheHostIsNotOverwrittenByThePoll() async throws {
        let fetcher = GatedTrackerFetcher()
        self.fetcher = fetcher
        keeper = ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date }, login: login)
        fetcher.release(TrackerFixtures.wiki)
        _ = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        await settle()
        clock.advance(20)
        await settle()
        XCTAssertEqual(fetcher.pending, 1, "the poll's fetch is out")
        let gate = HostGate()
        host.wait = { await gate.wait() }
        let tool = self.tool
        let updated = Task { await tool.run(["update", "A1", #"{"relevance": 90}"#]) }
        await settle()
        XCTAssertEqual(gate.held, 1, "the tool's update is in the host")
        fetcher.release(TrackerFixtures.wiki)
        await settle()
        host.wait = nil
        gate.openUp()
        let reply = await updated.value
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        await settle()
        XCTAssertEqual(host.updates, 1, "the poll wrote nothing over it: \(host.calls)")
        XCTAssertEqual(host.records[0].state.relevance, 90)
        keeper.forget("A1")
    }

    /// The other way round, through the tool: the poll's update is in the host when the tool's is
    /// asked for. The tool's waits its turn, merges over what the host then holds, and lands last.
    func testAToolUpdateWaitsForThePollsUpdateInTheHost() async throws {
        let fetcher = GatedTrackerFetcher()
        self.fetcher = fetcher
        keeper = ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date }, login: login)
        fetcher.release(TrackerFixtures.wiki)
        _ = await tool.run(["start", "job", #"{"poll": "https://h/progress/x"}"#])
        await settle()
        clock.advance(20)
        await settle()
        let gate = HostGate()
        host.wait = { await gate.wait() }
        let moved = TrackerFixtures.wiki.replacingOccurrences(of: #""label": "Download", "state": "running""#, with: #""label": "Download", "state": "done""#)
        fetcher.release(moved)
        await settle()
        XCTAssertEqual(gate.held, 1, "the poll's update is in the host")
        let tool = self.tool
        let updated = Task { await tool.run(["update", "A1", #"{"relevance": 90}"#]) }
        await settle()
        XCTAssertEqual(gate.held, 1, "the tool's waits at the keeper")
        host.wait = nil
        gate.openUp()
        let reply = await updated.value
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(host.updates, 2)
        XCTAssertEqual(host.records[0].state.relevance, 90, "the tool's update is the last applied")
        XCTAssertEqual(host.records[0].state.card?.steps[1].state, .done, "merged over the poll's card, not the one read before the wait")
        keeper.forget("A1")
    }

    /// One ended and still shown is taken down with
    /// `--dismiss now`, and not with the default or a last document.
    func testAnEndedActivityIsTakenDownWithDismissNow() async throws {
        _ = await tool.run(["start", "job", timer])
        _ = await tool.run(["end", "A1"])
        let again = await tool.run(["end", "A1"])
        XCTAssertEqual(again.status, ToolReply.failed, "the default is for one still running")
        let document = await tool.run(["end", "A1", "--dismiss", "now", timer])
        XCTAssertEqual(document.status, ToolReply.failed, "a last document is for one still running")
        let down = await tool.run(["end", "A1", "--dismiss", "now"])
        XCTAssertEqual(down.status, ToolReply.ok, down.text)
        XCTAssertEqual(down.text, "took down A1\n")
        guard case .end("A1", nil, .now) = host.ends.last else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(host.ends.count, 2)
    }

    func testUpdateReplacesWhatItCarries() async throws {
        _ = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "until": "2026-11-02T06:00:00Z"}"#])
        let reply = await tool.run(["update", "A1", #"{"tracker": \#(TrackerFixtures.tracker(steps: [("a", "done"), ("b", "running")], current: 1))}"#])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        guard case .update(let id, let state, let stale) = host.calls[1] else { return XCTFail("\(host.calls)") }
        XCTAssertEqual(id, "A1")
        XCTAssertEqual(state.card?.title, "A tracker")
        XCTAssertEqual(state.until, Date(timeIntervalSince1970: 1_793_599_200), "the until stands")
        XCTAssertEqual(stale, state.until)
        let reply6 = await tool.run(["update", "A9", timer])
        XCTAssertEqual(reply6.status, ToolReply.failed)
        let reply7 = await tool.run(["update", "A1", "nope"])
        XCTAssertEqual(reply7.status, ToolReply.usage)
    }

    func testEndTakesADismissalAndALastDocument() async throws {
        _ = await tool.run(["start", "job", timer])
        _ = await tool.run(["start", "two", timer])
        _ = await tool.run(["start", "three", timer])
        let reply8 = await tool.run(["end", "A1"])
        XCTAssertEqual(reply8.status, ToolReply.ok)
        let reply9 = await tool.run(["end", "A2", "--dismiss", "now"])
        XCTAssertEqual(reply9.status, ToolReply.ok)
        let last = await tool.run(["end", "A3", "--dismiss", "2026-11-02T05:30:00Z", #"{"tracker": \#(TrackerFixtures.tracker(steps: [("a", "done")], state: "done", ended: true))}"#])
        XCTAssertEqual(last.status, ToolReply.ok, last.text)
        XCTAssertEqual(host.ends.count, 3)
        guard case .end(_, nil, .standard) = host.ends[0], case .end(_, nil, .now) = host.ends[1],
              case .end(_, let state?, .at(let date)) = host.ends[2] else { return XCTFail("\(host.ends)") }
        XCTAssertEqual(state.card?.state, .done)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_793_597_400))
        let reply10 = await tool.run(["end", "A1"])
        XCTAssertEqual(reply10.status, ToolReply.failed, "ended twice")
        let reply11 = await tool.run(["end", "A4", "--dismiss", "soon"])
        XCTAssertEqual(reply11.status, ToolReply.usage)
        let reply12 = await tool.run(["end", "A4", "--dismiss"])
        XCTAssertEqual(reply12.status, ToolReply.usage)
    }

    func testSignOutEndsActivities() async throws {
        _ = await tool.run(["start", "job", timer])
        _ = await tool.run(["start", "two", #"{"tracker": \#(TrackerFixtures.wiki)}"#])
        await SigningOut.now(login)
        XCTAssertEqual(host.ends.count, 2)
        for end in host.ends {
            guard case .end(_, nil, .now) = end else { return XCTFail("\(end)") }
        }
        XCTAssertTrue(host.running().allSatisfy(\.ended))
        let started = ToolDates.write(clock.date), until = ToolDates.write(Date(timeIntervalSince1970: 1_793_599_200))
        let reply13 = await tool.run([])
        XCTAssertEqual(reply13.text, "activity: A1 | slot job | ended | started \(started) | until \(until)\n  families: lockScreen\nactivity: A2 | slot two | ended | started \(started)\n  tracker: macOS update on buddybox, 1 of 3 done, running, at Download\n")
    }

    func testExampleReads() async throws {
        let reply = await tool.run(["example"])
        XCTAssertEqual(reply.status, ToolReply.ok)
        let examples = ActivityTool.examples(now: clock.date)
        XCTAssertEqual(examples.count, 3)
        for example in examples {
            XCTAssertTrue(reply.text.contains(example.json), example.label)
            let reading = ActivityDocument.read(example.json, now: clock.date)
            XCTAssertTrue(reading.readable, example.label)
            XCTAssertEqual(reading.notes, [], example.label)
        }
    }

    // MARK: The call's login

    /// A start carries the login its launch was started under, not the one standing when it first
    /// reaches the main actor: a call made under a login that ends, and whose first hop runs only
    /// once the next login has begun, starts nothing under the next one.
    func testAStartFromALoginThatEndedStartsNothingUnderTheNext() async throws {
        let tool = self.tool
        let call = Task { await tool.run(["start", "tea", timer]) }
        // A sign-out's steps, then the next sign-in, all before the call has run at all: nothing
        // here suspends, so the call's task cannot run between them.
        login.moveEpoch()
        login.runTeardowns()
        login.began()
        let reply = await call.value
        await login.tornDown()
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(host.starts, 0, "an activity of the login that ended was started under the next")
        XCTAssertEqual(keeper.tasks, 0)
        XCTAssertFalse(keeper.isReserved("tea"))
    }

    /// A start already holding its call's login when that login ends starts nothing: it is parked
    /// while the sign-out's steps run and the next login begins, and only then goes on.
    func testAStartParkedAcrossASignOutAndTheNextSignInStartsNothing() async throws {
        let gate = Gate()
        var parking = bare
        parking.parked = { await gate.park() }
        let tool = Launched(tool: parking, login: login.epoch)
        let call = Task { await tool.run(["start", "tea", timer]) }
        await gate.reached()
        login.moveEpoch()
        login.runTeardowns()
        await login.tornDown()
        login.began()
        await gate.release()
        let reply = await call.value
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertEqual(host.starts, 0, "the start outlived the sign-out")
        XCTAssertEqual(keeper.tasks, 0)
        XCTAssertFalse(keeper.isReserved("tea"))
    }

    /// An update and an end from a login that ended change nothing of the next login's: an id
    /// listed under the next one reached by a call of the last does not reach its activity.
    func testAnUpdateAndAnEndFromALoginThatEndedChangeNothingOfTheNext() async throws {
        let old = self.tool
        await SigningOut.now(login)
        login.began()
        let started = await self.tool.run(["start", "tea", timer])
        XCTAssertEqual(started.status, ToolReply.ok, started.text)
        let update = await old.run(["update", "A1", #"{"relevance": 5}"#])
        let end = await old.run(["end", "A1"])
        XCTAssertEqual(update.status, ToolReply.failed, update.text)
        XCTAssertEqual(end.status, ToolReply.failed, end.text)
        XCTAssertEqual(host.updates, 0, "\(host.calls)")
        XCTAssertTrue(host.ends.isEmpty, "\(host.ends)")
        keeper.forget("A1")
    }

    /// A call that carries no login (one the service accepted on a listener no launch was told)
    /// starts, updates and ends nothing, and says why.
    func testACallCarryingNoLoginChangesNothing() async throws {
        _ = await tool.run(["start", "tea", timer])
        let start = await bare.run(["start", "job", timer])
        let update = await bare.run(["update", "A1", #"{"relevance": 5}"#])
        let end = await bare.run(["end", "A1"])
        for reply in [start, update, end] {
            XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
            XCTAssertTrue(reply.text.contains("no login"), reply.text)
        }
        XCTAssertEqual(host.starts, 1)
        XCTAssertEqual(host.updates, 0)
        XCTAssertTrue(host.ends.isEmpty)
        keeper.forget("A1")
    }

    func testHelpSaysWhatItCannotDo() {
        let usage = tool.usage
        for phrase in ["never while it is suspended", "locked phone", "No control and no image", "only while Topo is on the screen", "Settings"] {
            XCTAssertTrue(usage.contains(phrase), phrase)
        }
    }
}

/// A call as a launch's listener hands it on: run under the login it carries (`ToolCall.context`).
private struct Launched: Sendable {
    let tool: ActivityTool
    let login: LoginLife.Epoch
    var usage: String { tool.usage }

    func run(_ arguments: [String]) async -> ToolReply {
        await ToolCall.$context.withValue(login) { await tool.run(arguments) }
    }
}

/// Where a call waits: `park` holds it until `release`, and `reached` returns once it is held.
private actor Gate {
    private var parked: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var isParked = false

    func park() async {
        isParked = true
        arrived?.resume()
        arrived = nil
        await withCheckedContinuation { parked = $0 }
    }

    func reached() async {
        if isParked { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}
