import TopoCore
import TopoTools
import XCTest

@testable import Topo

/// `topo perf` (#773): a turn's time read off the perf marks as stages named for a person, over a
/// fake log reader.
final class PerfToolTests: XCTestCase {
    private struct Fixed: LogReading {
        var lines: [LogLine]
        func lines(since: Date) throws -> [LogLine] { lines }
    }

    private static let base: Int64 = 1_800_000_000_000

    private func line(_ ms: Int64, _ name: String, _ detail: String = "", category: String = "perf") -> LogLine {
        let t = Self.base + ms
        let message = detail.isEmpty ? "mark t=\(t) \(name)" : "mark t=\(t) \(name) \(detail)"
        return LogLine(at: Date(timeIntervalSince1970: Double(t) / 1000), level: "notice", category: category, message: message)
    }

    private func tool(_ lines: [LogLine]) -> PerfTool {
        PerfTool(reader: Fixed(lines: lines), now: { Date(timeIntervalSince1970: Double(Self.base) / 1000 + 600) })
    }

    /// A typed turn with every stage marked, from `at`, plus whatever `extra` lines.
    private func typed(at t: Int64) -> [LogLine] {
        [line(t, "turn.send"), line(t + 10, "turn.runner.made"), line(t + 300, "turn.person.saved"),
         line(t + 320, "turn.bridge.begin"), line(t + 500, "turn.guest.write"),
         line(t + 900, "proxy.request", "POST /v1/messages bytes=46080"), line(t + 1900, "proxy.head", "POST /v1/messages 200"),
         line(t + 2600, "proxy.firstByte", "POST /v1/messages"), line(t + 2700, "turn.text.first"),
         line(t + 2800, "turn.guest.toolUse"), line(t + 3000, "proxy.request", "POST /v1/messages bytes=47000"),
         line(t + 3500, "turn.guest.result"), line(t + 3600, "turn.brain.answered"), line(t + 3900, "turn.reply.saved"),
         line(t + 3950, "turn.reply.shown")]
    }

    func testATypedTurnIsItsStagesInWordsSummingToItsTime() async throws {
        let reply = await tool(typed(at: 0)).run(["turn"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("the last turn, at "), reply.text)
        XCTAssertTrue(reply.text.contains("typed: 3.95 s from your send to the reply on the screen"), reply.text)
        for title in ["Saving your words to iCloud", "Getting Claude Code ready", "Claude Code preparing the request",
                      "Sending the request (45 KB)", "Waiting for the model's first word", "First words on the screen",
                      "Writing the reply (1 tool, 2 model requests)", "Saving the reply to iCloud", "Drawing the reply"] {
            XCTAssertTrue(reply.text.contains(title), "\(title) missing from\n\(reply.text)")
        }
        XCTAssertFalse(reply.text.contains("Hearing you"))
        XCTAssertFalse(reply.text.contains("turn."), "a mark's name reached the answer:\n\(reply.text)")
        let record = try XCTUnwrap(reply.text.split(separator: "\n").last { $0.hasPrefix("record: ") })
        XCTAssertEqual(record, "record: perf-turn 2027-01-15T08:00:00Z typed answered total=3950 save=300 ready=200 prepare=400 "
                       + "upload=1000 first=700 screen=100 reply=800 store=400 show=50 bytes=46080 tools=1 requests=2")
    }

    func testStagesFollowOneAnotherFromZeroToTheTotal() async throws {
        let turn = try XCTUnwrap(TurnTimeline.turns(in: typed(at: 0).compactMap { PerfMark(message: $0.message) }).first)
        XCTAssertEqual(turn.spans.first?.start, 0)
        XCTAssertEqual(turn.spans.last?.end, turn.total)
        for (a, b) in zip(turn.spans, turn.spans.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertEqual(turn.spans.map(\.took).reduce(0, +), turn.total)
    }

    func testASpokenTurnStartsAtTheReleaseAndTheVoiceRunsAlongside() async {
        let lines = [line(-500, "voice.released"), line(-80, "voice.heard")] + typed(at: 0)
            + [line(4100, "speak.begin"), line(4400, "speak.firstFrame")]
        let reply = await tool(lines).run(["turn", "--tsv"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let rows = reply.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.first, "key\tstart_ms\ttook_ms\ttitle")
        XCTAssertEqual(rows[1], "hear\t0\t420\tHearing you")
        XCTAssertEqual(rows[2], "save\t420\t380\tSaving your words to iCloud")
        XCTAssertTrue(rows.contains("sound\t4600\t300\tThe voice's first sound"), reply.text)
        XCTAssertTrue(rows.last!.contains(" spoken answered total=4450 hear=420 "), rows.last!)
        XCTAssertTrue(rows.last!.contains(" sound=4900 "), rows.last!)
    }

    func testTheLastIsTheNewestFinishedTurnNotTheOneAsking() async {
        let lines = typed(at: 0) + typed(at: 10_000) + [line(20_000, "turn.send"), line(20_300, "turn.person.saved"),
                                                         line(20_500, "turn.guest.write")]
        let turns = await tool(lines).run(["turns"])
        XCTAssertEqual(turns.text.split(separator: "\n").count, 2, turns.text)
        XCTAssertTrue(turns.text.hasPrefix("back 1 | "), turns.text)
        let last = await tool(lines).run(["turn"])
        XCTAssertTrue(last.text.contains("perf-turn 2027-01-15T08:00:10Z"), last.text)
        let before = await tool(lines).run(["turn", "--back", "2"])
        XCTAssertTrue(before.text.hasPrefix("2 turns back"), before.text)
        XCTAssertTrue(before.text.contains("perf-turn 2027-01-15T08:00:00Z"), before.text)
        let past = await tool(lines).run(["turn", "--back", "3"])
        XCTAssertEqual(past.status, ToolReply.failed)
        XCTAssertTrue(past.text.contains("this launch has 2 finished turns"), past.text)
    }

    func testAResendCountsFromTheFirstSendAndOtherMarksAreNoStage() async throws {
        var lines = [line(-2000, "turn.send"), line(-1990, "lease.heartbeat", "held ms=40"), line(-1000, "energy", "cpu=0.2")]
        lines += typed(at: 0)
        lines.append(line(1200, "lease.heartbeat", "failed ms=4000"))
        let turn = try XCTUnwrap(TurnTimeline.turns(in: lines.compactMap { PerfMark(message: $0.message) }).first)
        XCTAssertEqual(turn.sends, 2)
        XCTAssertEqual(turn.total, 5950)
        XCTAssertEqual(turn.spans.first?.stage, .save)
        XCTAssertEqual(turn.spans.first?.took, 2300)
        let reply = await tool(lines).run(["turn"])
        XCTAssertTrue(reply.text.contains("its words were sent 2 times"), reply.text)
    }

    func testAStageWithNoMarkGivesItsTimeToTheNext() async throws {
        let lines = [line(0, "turn.send"), line(300, "turn.person.saved"), line(2000, "turn.text.first"),
                     line(2500, "turn.guest.result"), line(2700, "turn.reply.failed", "notHeld")]
        let turn = try XCTUnwrap(TurnTimeline.turns(in: lines.compactMap { PerfMark(message: $0.message) }).first)
        XCTAssertEqual(turn.spans.map(\.stage), [.save, .screen, .reply, .store])
        XCTAssertEqual(turn.spans.map(\.took), [300, 1700, 500, 200])
        XCTAssertFalse(turn.answered)
        XCTAssertNil(turn.requestBytes)
    }

    func testNoTurnIsSaidAsSoAndOnlyPerfLinesAreRead() async {
        let none = await tool([line(0, "turn.send"), line(10, "turn.reply.shown", category: "cloud")]).run(["turn"])
        XCTAssertEqual(none.status, ToolReply.failed)
        XCTAssertTrue(none.text.contains("no finished turn"), none.text)
        XCTAssertTrue(none.text.contains("perf off"), none.text)
        let listed = await tool([]).run(["turns"])
        XCTAssertEqual(listed.status, ToolReply.ok)
        XCTAssertTrue(listed.text.contains("no finished turn"), listed.text)
    }

    func testCallsItDoesNotTakeAreUsage() async {
        for arguments in [[], ["chart"], ["turn", "--back", "0"], ["turn", "--back", "51"], ["turn", "--back", "x"],
                          ["turns", "--tsv"], ["turn", "extra"]] {
            let reply = await tool([]).run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
    }
}

/// The two marks a spoken turn's hearing is timed by: the utterance taken off the microphone, and
/// the ear's decode returned, in that order, at every release that ends a session.
@MainActor
final class HearingMarksTests: XCTestCase {
    private final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        var all: [String] { lock.withLock { kept } }
        var add: @Sendable (String) -> Void { { [self] name in if name.hasPrefix("voice.") { lock.withLock { kept.append(name) } } } }
    }

    func testAReleaseMarksTheTakingAndTheHearing() async {
        let seams = Seams()
        let defaults = UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults), engine: ScriptedEngine())
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        for _ in 0..<400 where !ear.ready { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ear.ready)
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        let voice = VoiceInput(audio: audio, ear: ear, center: center, makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) }, voiceProcessing: { try seams.process($0, $1) },
                               defaults: defaults)
        await voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.listening)
        let names = Names()
        await Perf.$observer.withValue(names.add) {
            _ = await voice.end(as: .chat)
        }
        XCTAssertEqual(names.all, ["voice.released", "voice.heard"])
    }
}
