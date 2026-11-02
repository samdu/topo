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

    private var tool: ActivityTool {
        ActivityTool(host: { [host] in host! }, keeper: { [keeper] in keeper! }, fetcher: fetcher, now: { [clock] in clock!.date })
    }

    override func setUp() {
        host = FakeActivityHost()
        clock = FakeClock()
        fetcher = FakeTrackerFetcher([])
        keeper = ActivityKeeper(host: host, fetcher: fetcher, sleep: { [clock] in try await clock!.sleep($0) }, now: { [clock] in clock!.date })
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
        await settle()
        XCTAssertEqual(gate.pending, 1)
        await keeper.endAll()
        gate.release(TrackerFixtures.wiki)
        let reply = await started.value
        XCTAssertEqual(reply.status, ToolReply.failed, reply.text)
        XCTAssertTrue(reply.text.contains("login ended"), reply.text)
        XCTAssertEqual(host.starts, 0)
        XCTAssertEqual(keeper.tasks, 0)
        XCTAssertFalse(keeper.isReserved("job"), "the slot is free again")
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

    func testAnUpdateDuringASignOutKeepsNothing() async throws {
        _ = await tool.run(["start", "job", #"{"tracker": \#(TrackerFixtures.wiki), "until": "2026-11-02T06:00:00Z"}"#])
        await keeper.endAll()
        let reply = await tool.run(["update", "A1", #"{"relevance": 5}"#])
        XCTAssertEqual(reply.status, ToolReply.failed, "ended is not running")
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
        await keeper.endAll()
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

    func testHelpSaysWhatItCannotDo() {
        let usage = tool.usage
        for phrase in ["never while it is suspended", "locked phone", "No control and no image", "only while Topo is on the screen", "Settings"] {
            XCTAssertTrue(usage.contains(phrase), phrase)
        }
    }
}
