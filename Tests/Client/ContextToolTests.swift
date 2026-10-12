import TopoTools
import TopoTurn
import XCTest

@testable import Topo

/// `topo context` (#255): the mind reads its own context, sets when it is compacted and asks for
/// a compaction, over closures in place of the harness.
@MainActor
final class ContextToolTests: XCTestCase {
    private final class Phone: @unchecked Sendable {
        var facts = ContextTool.Facts(context: 142_000, window: 200_000, setting: .auto)
        var set: [Compaction.Setting] = []
        var asked = 0
        var canCompact = true
    }

    private func tool(_ phone: Phone) -> ContextTool {
        ContextTool(facts: { phone.facts }, set: { phone.set.append($0); phone.facts.setting = $0 },
                    compact: {
                        guard phone.canCompact, !phone.facts.compacting else { return false }
                        phone.asked += 1
                        phone.facts.compacting = true
                        return true
                    })
    }

    func testItShowsTheContextTheWindowAndTheThresholdOnOneScale() async {
        let phone = Phone()
        let shown = await tool(phone).run([])
        XCTAssertEqual(shown, .ok("""
        context: 142000 tokens
        window: 200000 tokens
        compacted at: 167000 tokens (auto, Claude Code's own)
        last compaction: none asked for in this launch

        """))
        phone.facts = ContextTool.Facts(context: nil, window: nil, setting: .percent(60))
        let unknown = await tool(phone).run(["show"])
        XCTAssertEqual(unknown.status, ToolReply.ok)
        XCTAssertTrue(unknown.text.contains("compacted at: 60%, set on this phone"), unknown.text)
        XCTAssertTrue(unknown.text.contains("window: not known"), unknown.text)
    }

    func testAThresholdIsSetAndReadBack() async {
        let phone = Phone()
        let reply = await tool(phone).run(["threshold", "60%"])
        XCTAssertEqual(phone.set, [.percent(60)])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertTrue(reply.text.contains("compacted at: 108000 tokens (60%, set on this phone)"), reply.text)
        XCTAssertTrue(reply.text.contains("from this turn's end"), reply.text)
        _ = await tool(phone).run(["threshold", "auto"])
        XCTAssertEqual(phone.set, [.percent(60), .auto])
    }

    func testAThresholdOutOfRangeChangesNothing() async {
        let phone = Phone()
        for word in ["0", "24", "101", "12.5", "nan", "sixty", "-50", ""] {
            let reply = await tool(phone).run(["threshold", word])
            XCTAssertEqual(reply.status, ToolReply.usage, word)
        }
        let bare = await tool(phone).run(["threshold"])
        XCTAssertEqual(bare.status, ToolReply.usage)
        let unknown = await tool(phone).run(["shrink"])
        XCTAssertEqual(unknown.status, ToolReply.usage)
        XCTAssertTrue(phone.set.isEmpty)
    }

    /// The call returns before the compaction has run: it is made from inside the turn whose end
    /// the compaction waits for, and says only that it is queued.
    func testCompactFromInsideATurnAnswersAtOnceAndRunsAfterIt() async {
        let phone = Phone()
        let reply = await tool(phone).run(["compact"])
        XCTAssertEqual(reply.status, ToolReply.ok)
        XCTAssertTrue(reply.text.hasPrefix("queued"), reply.text)
        XCTAssertEqual(phone.asked, 1)
        let again = await tool(phone).run(["compact"])
        XCTAssertEqual(again, .failed("a compaction is already waiting or running\n"))
        XCTAssertEqual(phone.asked, 1)
        let shown = await tool(phone).run([])
        XCTAssertTrue(shown.text.contains("last compaction: waiting or running"), shown.text)
    }

    /// What the compaction came to after the turn that asked is in the read-back, not the call.
    func testACompactionThatFailedAfterItsTurnIsInTheReadBack() async {
        let phone = Phone()
        _ = await tool(phone).run(["compact"])
        phone.facts.compacting = false
        phone.facts.last = Compaction.Outcome.failed("too_few_groups").words
        let shown = await tool(phone).run([])
        XCTAssertTrue(shown.text.contains("last compaction: failed: too_few_groups"), shown.text)
    }

    func testWithNoGuestItSaysSo() async {
        let phone = Phone()
        phone.canCompact = false
        let reply = await tool(phone).run(["compact"])
        XCTAssertEqual(reply, .failed("there is no guest to compact on this phone\n"))
    }

    func testTheSettingsStopsHoldAValueTheMindSet() {
        XCTAssertEqual(ContextSection.stops(kept: 0), [0, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95])
        XCTAssertEqual(ContextSection.stops(kept: 60).count, 11)
        XCTAssertEqual(ContextSection.stops(kept: 83), [0, 50, 55, 60, 65, 70, 75, 80, 83, 85, 90, 95])
        XCTAssertEqual(ContextSection.stops(kept: 25).prefix(3), [0, 25, 50])
        XCTAssertEqual(ContextSection.stops(kept: 7), ContextSection.stops(kept: 0), "a number no setting reads as was offered")
        XCTAssertEqual(ContextSection.title(0), "Automatic")
        XCTAssertEqual(ContextSection.title(83), "83%")
        XCTAssertEqual(ContextSection.fill(context: 142_300, window: 200_000), "142k of 200k")
        XCTAssertEqual(ContextSection.fill(context: nil, window: 200_000), "not known yet")
    }
}
