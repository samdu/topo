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
        var threads: [MessageThreads.Setting] = []
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
                    },
                    setThreads: { phone.threads.append($0); phone.facts.threads = $0 })
    }

    /// The check is what the requests uploaded, not the setting: a launch whose name Claude Code
    /// does not read shows on, with every request whole, which is how the mind tells a dead name.
    func testThreadsShowsWhatTheRequestsUploadedBesideTheSetting() async {
        let phone = Phone()
        let now = Date(timeIntervalSince1970: 1_000)
        phone.facts.now = now
        phone.facts.sent = [
            ThreadSampler.Note(at: now - 400, bytes: 21_000, tokens: 14_000, kind: .whole),
            ThreadSampler.Note(at: now - 380, bytes: 2_600, tokens: 14_600, kind: .thread),
            ThreadSampler.Note(at: now - 2, bytes: nil, tokens: 15_000, kind: .unknown),
            ThreadSampler.Note(at: now - 1, bytes: 2_700, tokens: 15_100, kind: .thread),
        ]
        let shown = await tool(phone).run(["threads"])
        XCTAssertEqual(shown.status, ToolReply.ok)
        XCTAssertTrue(shown.text.hasPrefix("threads: on, asked for with CLAUDE_CODE_TETHER_LIVE=1"), shown.text)
        XCTAssertTrue(shown.text.contains("up to an hour after the last request; no delete; not zero data retention"), shown.text)
        // What else on sends, and to whom, so the mind can say it to its person.
        XCTAssertTrue(shown.text.contains("also sent: \(MessageThreads.alsoSent)\noff: \(MessageThreads.whenOff)\n"), shown.text)
        for named in ["Anthropic", "Datadog", "feature flags", "public MCP registry", "account and organisation ids", "session's id", "plan"] {
            XCTAssertTrue(MessageThreads.alsoSent.contains(named), named)
        }
        XCTAssertTrue(MessageThreads.alsoSent.contains("start-up settings"), "on's start-up fetch is unsaid")
        for named in ["profile", "claude.ai connectors", "whole conversation"] {
            XCTAssertTrue(MessageThreads.whenOff.contains(named), named)
        }
        XCTAssertTrue(shown.text.contains("judged by their uploads (inferred, never read)"), shown.text)
        XCTAssertTrue(shown.text.contains("  400 s ago  whole conversation  21 KB for 14000 tokens\n"), shown.text)
        XCTAssertTrue(shown.text.contains("  380 s ago  small upload: on a thread  3 KB for 14600 tokens\n"), shown.text)
        XCTAssertTrue(shown.text.contains("  2 s ago  can't tell  upload not told apart"), shown.text)
        XCTAssertTrue(shown.text.hasSuffix("small uploads: 2 of 4; the newest: small upload: on a thread\n"), shown.text)

        phone.facts.threads = MessageThreads.Setting(on: true, variable: "CLAUDE_CODE_THREADS_WRONG_NAME")
        phone.facts.sent = [ThreadSampler.Note(at: now - 1, bytes: 16_100, tokens: 9_800, kind: .whole)]
        let dead = await tool(phone).run(["threads"])
        XCTAssertTrue(dead.text.hasPrefix("threads: on, asked for with CLAUDE_CODE_THREADS_WRONG_NAME=1 (renamed on this phone)"), dead.text)
        XCTAssertTrue(dead.text.hasSuffix("small uploads: none of these; the newest: whole conversation\n"), dead.text)

        phone.facts.sent = []
        let none = await tool(phone).run(["threads"])
        XCTAssertTrue(none.text.contains("requests: none seen since this app launched"), none.text)
        XCTAssertEqual(phone.threads, [], "showing changed the setting")
    }

    func testThreadsAreTurnedOffAndOnAndRenamedWithinTheReadersShape() async {
        let phone = Phone()
        let off = await tool(phone).run(["threads", "off"])
        XCTAssertEqual(off.status, ToolReply.ok)
        XCTAssertTrue(off.text.hasPrefix("threads: off"), off.text)
        XCTAssertTrue(off.text.contains("off: \(MessageThreads.whenOff)\non would send: \(MessageThreads.alsoSent)\n"), off.text)
        XCTAssertTrue(off.text.contains("from this turn's end"), off.text)
        let renamed = await tool(phone).run(["threads", "variable", "CLAUDE_CODE_MESSAGE_THREADS"])
        XCTAssertEqual(renamed.status, ToolReply.ok)
        _ = await tool(phone).run(["threads", "on"])
        _ = await tool(phone).run(["threads", "variable", "default"])
        XCTAssertEqual(phone.threads, [
            MessageThreads.Setting(on: false, variable: "CLAUDE_CODE_TETHER_LIVE"),
            MessageThreads.Setting(on: false, variable: "CLAUDE_CODE_MESSAGE_THREADS"),
            MessageThreads.Setting(on: true, variable: "CLAUDE_CODE_MESSAGE_THREADS"),
            MessageThreads.Setting(on: true, variable: "CLAUDE_CODE_TETHER_LIVE"),
        ])
        for arguments in [["threads", "variable", "CLAUDE_CODE_OAUTH_TOKEN"], ["threads", "variable", "ANTHROPIC_BASE_URL"],
                          ["threads", "variable", "HOME"], ["threads", "variable"], ["threads", "variable", "A", "B"],
                          ["threads", "maybe"], ["threads", "on", "now"]] {
            let reply = await tool(phone).run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments)")
        }
        XCTAssertEqual(phone.threads.count, 4, "a refused name changed the setting")
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
        // The help says threads send telemetry naming the account, and sends the mind to the whole of it.
        for named in ["Anthropic and Datadog its telemetry", "naming the person's account", "topo context threads says whole", "with what off still sends"] {
            XCTAssertTrue(unknown.text.contains(named), named)
        }
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
