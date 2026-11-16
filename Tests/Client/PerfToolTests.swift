import TopoCore
import TopoTools
import XCTest

@testable import Topo

/// `topo perf` (#773): a turn's time read off the perf marks as the things that happened, in a
/// person's words, over a fake log reader. The fixtures keep the order of a real phone session's
/// marks (topo-perf `2026-10-04-roundtrips-after`, its second turn), with the tagged marks put where
/// the app makes them.
final class PerfToolTests: XCTestCase {
    /// A store that holds `lines` and answers those from `since` on, as `OSLogStore`'s predicate does.
    private struct Fixed: LogReading {
        var lines: [LogLine]
        func lines(since: Date) throws -> [LogLine] { lines.filter { $0.at >= since } }
    }

    private static let base: Int64 = 1_800_000_000_000

    private func line(_ ms: Int64, _ name: String, _ detail: String = "", category: String = "perf") -> LogLine {
        let t = Self.base + ms
        let message = detail.isEmpty ? "mark t=\(t) \(name)" : "mark t=\(t) \(name) \(detail)"
        return LogLine(at: Date(timeIntervalSince1970: Double(t) / 1000), level: "notice", category: category, message: message)
    }

    private func tool(_ lines: [LogLine]) -> PerfTool {
        PerfTool(reader: Fixed(lines: lines))
    }

    private func timelines(_ lines: [LogLine]) -> [TurnTimeline] {
        TurnTimeline.turns(in: lines.compactMap { PerfMark(message: $0.message) })
    }

    /// A typed turn as the phone marked one, moved to `t`, tagged `id`, its request marked as the
    /// stream marks one.
    private func typed(at t: Int64, id: String = "aaaa1111") -> [LogLine] {
        let tag = "turn=\(id)"
        return [
            line(t, "turn.line", tag), line(t + 1, "turn.attempt", tag), line(t + 1, "turn.send"), line(t + 2, "turn.begin"),
            line(t + 7, "zone.read.begin", "Turn"), line(t + 782, "turn.lease.acquired"), line(t + 2612, "turn.log.read"),
            line(t + 3150, "turn.saved"), line(t + 3184, "turn.person.saved"), line(t + 3205, "turn.bridge.begin"),
            line(t + 3213, "turn.guest.write"), line(t + 3701, "turn.guest.init"),
            line(t + 6542, "turn.guest.message", "own guest=1 request=1 tokens=13305"), line(t + 6543, "turn.guest.upload", "guest=1 request=1 kind=thread bytes=2662"),
            line(t + 6575, "turn.text.first"), line(t + 7068, "turn.guest.message.done", "own"),
            line(t + 7184, "turn.guest.result"), line(t + 7191, "turn.brain.answered"), line(t + 7780, "turn.reply.saved"),
            line(t + 7795, "turn.reply.shown", tag), line(t + 8400, "turn.pass.done"), line(t + 8401, "turn.attempt.end", "\(tag) answered"),
            line(t + 8371, "zone.read.begin", "Note"),
        ]
    }

    func testATypedTurnIsWhatHappenedInOrderEachTimedFromTheOneBefore() async throws {
        let reply = await tool(typed(at: 0)).run(["turn", "--tsv"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertEqual(reply.text.split(separator: "\n").map(String.init), [
            "key\tat_ms\ttook_ms\ttitle",
            "queue\t1\t1\tStarted on its way",
            "save\t3150\t3149\tYour words saved to iCloud",
            "ready\t3213\t63\tClaude Code had your words",
            "start\t3701\t488\tClaude Code started on your words",
            "model\t6542\t2841\tRequest 1 sent and the model began answering (3 KB, a small upload: on a thread)",
            "screen\t6575\t33\tFirst words on your screen",
            "stream\t7068\t493\tThe model finished request 1",
            "finish\t7184\t116\tClaude Code finished the reply",
            "store\t7780\t596\tThe reply saved to iCloud",
            "show\t7795\t15\tThe reply on your screen",
            "record: perf-turn 2027-01-15T08:00:00Z typed answered total=7795 queue=1 save=3149 ready=63 start=488 "
                + "model=2841 stream=493 screen=33 finish=116 store=596 show=15 thread=thread bytes=2662 requests=1 tools=0 sends=1",
        ])
        let turn = try XCTUnwrap(timelines(typed(at: 0)).first)
        XCTAssertEqual(turn.events.map(\.took).reduce(0, +), turn.total)
    }

    func testTheWordsSayNothingButTitlesTimesAndCounts() async {
        let reply = await tool(typed(at: 0)).run(["turn"])
        XCTAssertTrue(reply.text.hasPrefix("the last turn, at "), reply.text)
        XCTAssertTrue(reply.text.contains("typed: 7.79 s from your send to the reply on your screen"), reply.text)
        XCTAssertTrue(reply.text.contains("Request 1 sent and the model began answering (3 KB, a small upload: on a thread)"), reply.text)
        for leak in ["turn.", "tokens=", "kind=", "13305", "aaaa1111"] {
            XCTAssertFalse(reply.text.contains(leak), "\(leak) reached the answer:\n\(reply.text)")
        }
    }

    func testMarksReadOutOfOrderAreTimedInTheOrderTheyHappened() throws {
        let lines = typed(at: 0)
        let turn = try XCTUnwrap(timelines(lines.reversed()).first)
        XCTAssertEqual(turn.events, try XCTUnwrap(timelines(lines).first).events)
        XCTAssertEqual(turn.events.map(\.at), turn.events.map(\.at).sorted())
    }

    /// Words given to the guest ahead (`hearLine`) reach it before the attempt and before the save.
    func testWordsHeardAheadAreReadyBeforeTheyAreSaved() throws {
        let tag = "turn=bbbb2222"
        let lines = [line(0, "turn.line", tag), line(40, "turn.guest.write"), line(60, "turn.attempt", tag),
                     line(900, "turn.saved"), line(950, "turn.person.saved"),
                     line(2500, "turn.guest.message", "own guest=1 request=1 tokens=8000"), line(2501, "turn.guest.upload", "guest=1 request=1 kind=thread bytes=2048"),
                     line(2600, "turn.text.first"), line(2700, "turn.guest.message.done", "own"), line(2800, "turn.guest.result"),
                     line(3000, "turn.reply.saved"), line(3010, "turn.reply.shown", tag), line(3010, "turn.attempt.end", "\(tag) answered")]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertEqual(turn.events.map(\.key), [.ready, .queue, .model, .screen, .stream, .finish, .store, .show])
        XCTAssertEqual(turn.events.first?.took, 40)
        XCTAssertEqual(turn.events[2].took, 2440, "the save took the wait for the request")
        XCTAssertEqual(turn.beside, [.init(key: .save, title: "Your words saved to iCloud, while Claude Code worked", at: 60, took: 840)])
        XCTAssertEqual(turn.events.map(\.took).reduce(0, +), turn.total)
        XCTAssertTrue(turn.record.contains(" saved=900 "), turn.record)
        let said = PerfTool.describe(turn, back: 1)
        let row = said.split(separator: "\n").first { $0.contains("Your words saved to iCloud, while Claude Code worked") }
        XCTAssertTrue(row?.hasSuffix("  at 0.06 s  took 0.84 s") == true, said)
        XCTAssertEqual(turn.requestBytes, [2048])
    }

    /// A message sent while a turn is under way has its own marks among that turn's: the stretch
    /// they share is said as one, and neither turn takes the other's events.
    func testAnotherTurnUnderWayIsSaidAsOneStretchAndStealsNothing() throws {
        var lines = typed(at: 0)
        lines += [line(5000, "turn.line", "turn=cccc3333"), line(5010, "turn.guest.write")]
        lines += [line(7800, "turn.attempt", "turn=cccc3333"), line(9000, "turn.saved"), line(9100, "turn.reply.shown", "turn=cccc3333"),
                  line(9100, "turn.attempt.end", "turn=cccc3333 answered")]
        let turns = timelines(lines)
        XCTAssertEqual(turns.count, 2)
        let first = turns[0]
        XCTAssertTrue(first.mixed)
        XCTAssertEqual(first.events.map(\.key), [.queue, .save, .ready, .start, .wait, .mixed, .show])
        XCTAssertEqual(first.events[4], .init(key: .wait, title: "Another message began", at: 5000, took: 1299))
        XCTAssertEqual(first.events.last?.at, 7795)
        XCTAssertEqual(first.events.map(\.took).reduce(0, +), first.total)
        XCTAssertTrue(first.record.hasSuffix(" mixed"), first.record)
        let second = turns[1]
        XCTAssertTrue(second.mixed)
        XCTAssertFalse(second.events.contains { $0.key == .ready }, "the second turn took the first's guest write")
        // The first's pass after its reply was drawn is no wait of either turn's, so the stretch
        // ends at that reply and the second's own attempt after it is its own.
        XCTAssertEqual(Array(second.events.prefix(2)), [.init(key: .mixed, title: "Alongside another message", at: 2795, took: 2795),
                                                        .init(key: .queue, title: "Started on its way", at: 2800, took: 5)])
    }

    private func short(_ id: String, from t: Int64, to end: Int64) -> [LogLine] {
        let tag = "turn=\(id)"
        return [line(t, "turn.line", tag), line(t + 1, "turn.attempt", tag),
                line(end, "turn.reply.shown", tag), line(end, "turn.attempt.end", "\(tag) answered")]
    }

    /// Two messages sent at two moments of a long turn are two stretches: the turn's own events
    /// between them are read, and the wait up to each is its own, not the stretch's.
    func testTwoOverlapsAreTwoStretchesEachFromWhereTheOtherBegan() throws {
        let lines = typed(at: 0) + short("dddd4444", from: 1000, to: 2000) + short("eeee5555", from: 6000, to: 6500)
        let turns = timelines(lines)
        XCTAssertEqual(turns.count, 3)
        let turn = turns[2]
        XCTAssertEqual(turn.events.map(\.key), [.queue, .wait, .mixed, .save, .ready, .start, .wait, .mixed,
                                                 .model, .screen, .stream, .finish, .store, .show])
        XCTAssertEqual(turn.events.filter { $0.key == .mixed }.map(\.took), [1000, 500])
        XCTAssertEqual(turn.events.filter { $0.key == .wait }.map(\.took), [999, 2299])
        XCTAssertEqual(turn.events.map(\.took).reduce(0, +), turn.total)
        XCTAssertTrue(turn.record.contains(" wait=3298 mixed=1500 "), turn.record)
    }

    /// The voice's first sound is the turn's own reply's, by its tag: another turn's, after a turn
    /// that overlapped it, and a replay, which answers no turn, are never it.
    func testTheVoiceIsTheTurnsOwnReplysAndNeverAReplay() throws {
        var lines = typed(at: 0) + [line(5000, "turn.line", "turn=cccc3333"), line(5001, "turn.attempt", "turn=cccc3333"),
                                    line(9100, "turn.reply.shown", "turn=cccc3333"), line(9100, "turn.attempt.end", "turn=cccc3333 answered"),
                                    line(9200, "speak.begin", "turn=cccc3333"), line(9400, "speak.firstFrame")]
        var turns = timelines(lines)
        XCTAssertNil(turns[0].sound, "the first took the second's voice")
        XCTAssertEqual(turns[1].sound, 4200...4400)
        lines = typed(at: 0) + [line(8500, "speak.begin", "replay"), line(8700, "speak.firstFrame")]
        turns = timelines(lines)
        XCTAssertNil(turns[0].sound, "a replay's voice was the turn's")
        lines = typed(at: 0) + [line(7000, "speak.begin", "turn=aaaa1111"), line(7100, "speak.begin", "replay"), line(7300, "speak.firstFrame")]
        XCTAssertNil(timelines(lines)[0].sound, "a replay's first frame was the turn's")
    }

    /// A turn's own attempt inside a stretch another turn shared is not said, so the stretch keeps
    /// its whole length and the attempt takes none of it.
    func testAnAttemptInsideASharedStretchTakesNoneOfIt() throws {
        let a = "turn=ffff6666"
        let lines = [line(0, "turn.line", a), line(1, "turn.attempt", a), line(200, "turn.attempt.end", "\(a) unsaved"),
                     line(600, "turn.attempt", a), line(1000, "turn.reply.shown", a), line(1000, "turn.attempt.end", "\(a) answered")]
            + short("gggg7777", from: 500, to: 700)
        let turn = try XCTUnwrap(timelines(lines).last)
        XCTAssertEqual(turn.events, [.init(key: .queue, title: "Started on its way", at: 1, took: 1),
                                     .init(key: .wait, title: "Another message began", at: 500, took: 499),
                                     .init(key: .mixed, title: "Alongside another message", at: 700, took: 200),
                                     .init(key: .show, title: "The reply on your screen", at: 1000, took: 300)])
        XCTAssertEqual(turn.sends, 2)
    }

    /// Marks can share a millisecond, so the voice is read by the marks' order: a replay begun in
    /// the same millisecond as the turn's own voice is not the turn's, nor a frame that came before.
    func testTheVoiceIsReadByTheMarksOrderWithinAMillisecond() {
        var lines = typed(at: 0) + [line(8000, "speak.begin", "turn=aaaa1111"), line(8000, "speak.begin", "replay"), line(8100, "speak.firstFrame")]
        XCTAssertNil(timelines(lines)[0].sound, "a replay's first frame was the turn's")
        lines = typed(at: 0) + [line(8000, "speak.firstFrame"), line(8000, "speak.begin", "turn=aaaa1111")]
        XCTAssertNil(timelines(lines)[0].sound, "a frame before the turn's voice began was its first sound")
        lines = typed(at: 0) + [line(8000, "speak.begin", "turn=aaaa1111"), line(8000, "speak.firstFrame")]
        XCTAssertEqual(timelines(lines)[0].sound, 8000...8000)
    }

    /// A reply kept on screen while only its save failed is answered, with iCloud behind on it.
    func testAReplyKeptWhileItsSaveFailedIsAnswered() throws {
        let lines = typed(at: 0).map { $0.message.hasSuffix(" turn.reply.saved") ? line(7780, "turn.reply.failed", "unavailable") : $0 }
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertTrue(turn.answered)
        XCTAssertEqual(turn.events.suffix(2).map(\.title), ["iCloud had not taken the reply yet", "The reply on your screen"])
    }

    /// Events of one millisecond are said in the order their marks were made.
    func testEventsOfOneMillisecondAreInTheMarksOrder() throws {
        func keys(textFirst: Bool) throws -> [TurnTimeline.Key] {
            let words = line(7068, "turn.text.first"), done = line(7068, "turn.guest.message.done", "own")
            let lines = typed(at: 0).filter { !$0.message.contains(" turn.text.first") && !$0.message.contains(" turn.guest.message.done ") }
                + (textFirst ? [words, done] : [done, words])
            return try XCTUnwrap(timelines(lines).first).events.map(\.key)
        }
        XCTAssertEqual(try keys(textFirst: true).suffix(6), [.model, .screen, .stream, .finish, .store, .show])
        XCTAssertEqual(try keys(textFirst: false).suffix(6), [.model, .stream, .screen, .finish, .store, .show])
    }

    /// The store is this launch's alone and is read whole, so a turn of a launch days old is there.
    func testATurnOfALongLaunchIsRead() async {
        let reply = await tool(typed(at: -3 * 86_400_000)).run(["turns"])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("typed"), reply.text)
        XCTAssertFalse(reply.text.contains(PerfTool.noTurns), reply.text)
    }

    /// A dictation is a release and a hearing with no turn: the typed turn after it is typed and
    /// begins at its own words.
    func testATypedTurnAfterADictationIsTypedFromItsOwnWords() throws {
        let lines = [line(-3000, "voice.released"), line(-2600, "voice.heard")] + typed(at: 0)
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertEqual(turn.kind, .typed)
        XCTAssertEqual(turn.at, Date(timeIntervalSince1970: Double(Self.base) / 1000))
        XCTAssertFalse(turn.events.contains { $0.key == .hear })
    }

    func testASpokenTurnBeginsAtItsReleaseWithTheVoiceAlongside() async {
        var lines = [line(-4000, "voice.released"), line(-3800, "voice.heard"),
                     line(-500, "voice.released"), line(-80, "voice.heard"), line(-70, "turn.spoken", "turn=aaaa1111")]
        lines += typed(at: 0) + [line(8100, "speak.begin", "turn=aaaa1111"), line(8400, "speak.firstFrame")]
        let reply = await tool(lines).run(["turn", "--tsv"])
        let rows = reply.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[1], "hear\t420\t420\tHeard you")
        XCTAssertEqual(rows[2], "queue\t501\t81\tStarted on its way")
        XCTAssertEqual(rows[rows.count - 2], "sound\t8600\t300\tThe voice's first sound")
        XCTAssertTrue(rows.last!.contains(" spoken answered total=8295 hear=420 queue=81 "), rows.last!)
        XCTAssertTrue(rows.last!.contains(" sound=8900 "), rows.last!)
    }

    /// A hearing in the line's own millisecond but after it, by the marks' order, is the next
    /// utterance's: the turn begins at the release before its own.
    func testASpokenTurnsReleaseIsReadByTheMarksOrder() throws {
        var lines = [line(-4000, "voice.released"), line(-3800, "voice.heard"), line(-70, "turn.spoken", "turn=aaaa1111")]
        lines += typed(at: 0) + [line(-30, "voice.released"), line(0, "voice.heard")]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertEqual(turn.at, Date(timeIntervalSince1970: Double(Self.base - 4000) / 1000))
        XCTAssertEqual(turn.events.first?.title, "Heard you")
        XCTAssertEqual(turn.events.first?.took, 200)
        XCTAssertEqual(turn.total, 11_795)
    }

    /// A release from before another turn's words went on the line is not this turn's: it begins
    /// at its own line, with no hearing in it.
    func testASpokenTurnTakesNoReleaseFromBeforeAnotherTurn() throws {
        var lines = [line(-60_000, "voice.released"), line(-59_600, "voice.heard"), line(-59_590, "turn.line", "turn=0000ffff")]
        lines += [line(-70, "turn.spoken", "turn=aaaa1111")] + typed(at: 0)
        let turn = try XCTUnwrap(timelines(lines).first { $0.total == 7795 })
        XCTAssertEqual(turn.kind, .spoken)
        XCTAssertEqual(turn.at, Date(timeIntervalSince1970: Double(Self.base) / 1000))
        XCTAssertFalse(turn.events.contains { $0.key == .hear })
    }

    /// A turn that never ended here (a hub answered it, or it is still under way) is no turn, and
    /// one that is only on the line takes nothing from the turns after it.
    func testATurnWithNoEndIsNoneAndMixesWithNothingAfter() throws {
        var lines = [line(-9000, "turn.line", "turn=dddd4444"), line(-8000, "turn.line", "turn=eeee5555"),
                     line(-7990, "turn.attempt", "turn=eeee5555"), line(-7000, "turn.saved")]
        lines += typed(at: 0)
        let turns = timelines(lines)
        XCTAssertEqual(turns.count, 1)
        XCTAssertFalse(turns[0].mixed)
        XCTAssertEqual(turns[0].total, 7795)
    }

    func testAFailedTurnEndsWithNoReplyAndASendAgainIsCounted() throws {
        let tag = "turn=ffff6666"
        let lines = [line(0, "turn.line", tag), line(5, "turn.attempt", tag), line(800, "turn.unsaved"),
                     line(900, "turn.attempt.end", "\(tag) ended"), line(4000, "turn.attempt", tag),
                     line(4600, "turn.reply.failed", "notHeld"), line(4600, "turn.attempt.end", "\(tag) ended")]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertFalse(turn.answered)
        XCTAssertEqual(turn.sends, 2)
        XCTAssertEqual(turn.events.map(\.title), ["Started on its way", "iCloud had not taken your words yet", "Sent again",
                                                   "The reply failed", "The turn ended with no reply here"])
        XCTAssertEqual(turn.events.map(\.took), [5, 795, 3200, 600, 0])
        XCTAssertTrue(turn.record.contains(" typed ended total=4600 "), turn.record)
    }

    /// A tool run before any words reached the screen is the wait from the answer that called it
    /// to its result; the model's wait for the next request follows it.
    func testAToolBeforeAnyWordsIsItsOwnWaitBeforeTheNextRequest() throws {
        let tag = "turn=abcd0000"
        let lines = [line(0, "turn.line", tag), line(1, "turn.attempt", tag), line(300, "turn.saved"), line(320, "turn.guest.write"),
                     line(1900, "turn.guest.message", "own guest=1 request=1 tokens=800"), line(1901, "turn.guest.upload", "guest=1 request=1 kind=whole bytes=1000"),
                     line(2000, "turn.guest.message.done", "own"), line(2100, "turn.guest.toolUse"), line(2400, "turn.guest.toolResult"),
                     line(3000, "turn.guest.message", "own guest=1 request=2 tokens=900"), line(3001, "turn.guest.upload", "guest=1 request=2 kind=thread bytes=150"),
                     line(3050, "turn.text.first"), line(3300, "turn.guest.message.done", "own"),
                     line(3400, "turn.guest.result"), line(3600, "turn.reply.saved"), line(3610, "turn.reply.shown", tag),
                     line(3610, "turn.attempt.end", "\(tag) answered")]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertEqual(turn.events.map(\.key), [.queue, .save, .ready, .model, .stream,
                                                 .tool, .model, .screen, .stream, .finish, .store, .show])
        XCTAssertEqual(turn.events[5], .init(key: .tool, title: "A tool ran", at: 2400, took: 400))
        XCTAssertEqual(turn.events[6].took, 600)
        XCTAssertEqual(turn.tools, 1)
        XCTAssertEqual(turn.requests, 2)
        XCTAssertEqual(turn.requestBytes, [1000, 150])
        XCTAssertEqual(turn.requestThreads, ["whole", "thread"])
        XCTAssertTrue(turn.record.contains(" thread=whole bytes=1150 requests=2 tools=1 "), turn.record)
    }

    /// An attempt iCloud was behind for leaves the guest answering: the turn is still in flight,
    /// so a `topo perf` from its own reply does not take it for the last.
    func testATurnTheGuestIsStillAnsweringIsNotFinished() throws {
        let tag = "turn=9999aaaa"
        var lines = typed(at: 0)
        lines += [line(10_000, "turn.line", tag), line(10_001, "turn.attempt", tag), line(10_020, "turn.guest.write"),
                  line(14_000, "turn.unsaved"), line(14_000, "turn.attempt.end", "\(tag) unsaved")]
        XCTAssertEqual(timelines(lines).map(\.total), [7795])
        lines += [line(20_000, "turn.attempt", tag), line(20_500, "turn.saved"), line(20_600, "turn.reply.shown", tag),
                  line(20_600, "turn.attempt.end", "\(tag) answered")]
        let turns = timelines(lines)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].sends, 2)
        XCTAssertEqual(turns[1].total, 10_600)
    }

    /// A sub-agent's requests run beside the turn's own and are none of its requests, and a retry,
    /// which names no request, is said beside the stages and splits none; an upload not told says so.
    func testASubagentsRequestIsNotTheTurnsAndARetryIsAWait() throws {
        let tag = "turn=1234abcd"
        let lines = [line(0, "turn.line", tag), line(1, "turn.attempt", tag), line(50, "turn.saved"), line(60, "turn.guest.write"),
                     line(200, "turn.guest.retry", "attempt=1 status=529"),
                     line(400, "turn.guest.message", "own guest=1 request=1 tokens=1000"), line(401, "turn.guest.upload", "guest=1 request=1 kind=unknown bytes=unknown"),
                     line(450, "turn.guest.message", "agent tokens=300"), line(600, "turn.guest.message.done", "agent"),
                     line(700, "turn.guest.message.done", "own"), line(800, "turn.reply.shown", tag),
                     line(800, "turn.attempt.end", "\(tag) answered")]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertEqual(turn.events.map(\.key), [.queue, .save, .ready, .model, .stream, .show])
        XCTAssertEqual(turn.events[3], .init(key: .model, title: "Request 1 sent and the model began answering (upload not told)",
                                             at: 400, took: 340), "a retry split the model's stage")
        XCTAssertEqual(turn.events[4], .init(key: .stream, title: "The model finished request 1", at: 700, took: 300))
        XCTAssertEqual(turn.beside, [.init(key: .wait, title: "A request failed and Claude Code tried again (529)", at: 200, took: 0)])
        XCTAssertEqual(turn.requests, 1)
        XCTAssertEqual(turn.requestBytes, [])
        XCTAssertTrue(turn.record.contains(" thread=unknown bytes=0 requests=1 "), turn.record)
    }

    /// Each request's upload is its own by its turn's number and its own, however late the sampler's
    /// queue marks it: after the next request has begun, after the turn has ended, after the next
    /// turn's words were written and its own request's upload; and a request whose answer ends in the
    /// millisecond the next begins is ended where it ended, by the marks' order.
    func testARequestsMarksAreItsOwnByNumberAndOrder() throws {
        let tag = "turn=5ca1ab1e", next = "turn=0ddba11e"
        let lines = [line(0, "turn.line", tag), line(1, "turn.attempt", tag), line(50, "turn.saved"), line(60, "turn.guest.write", "guest=4"),
                     line(400, "turn.guest.message", "own guest=4 request=1 tokens=13000"),
                     line(900, "turn.guest.message.done", "own"), line(900, "turn.guest.message", "own guest=4 request=2 tokens=13100"),
                     line(901, "turn.guest.upload", "guest=4 request=1 kind=whole bytes=21000"),
                     line(1500, "turn.guest.message.done", "own"), line(1600, "turn.reply.shown", tag),
                     line(1600, "turn.attempt.end", "\(tag) answered"),
                     line(5000, "turn.line", next), line(5001, "turn.attempt", next), line(5002, "turn.saved"),
                     line(5003, "turn.guest.write", "guest=5"),
                     line(5300, "turn.guest.message", "own guest=5 request=1 tokens=13200"),
                     line(5301, "turn.guest.upload", "guest=5 request=1 kind=thread bytes=2700"),
                     line(5400, "turn.guest.upload", "guest=4 request=2 kind=thread bytes=2600"),
                     line(5900, "turn.guest.message.done", "own"), line(6000, "turn.reply.shown", next),
                     line(6000, "turn.attempt.end", "\(next) answered")]
        let turns = timelines(lines)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].requestBytes, [21000, 2600], "an upload was given to another request, or lost past the next turn's words")
        XCTAssertEqual(turns[0].requestThreads, ["whole", "thread"])
        XCTAssertEqual(turns[1].requestBytes, [2700], "the next turn took the last turn's upload")
        XCTAssertEqual(turns[0].events.filter { $0.key == .stream }.map(\.at), [900, 1500],
                       "request 2 was ended by request 1's end")
        XCTAssertEqual(turns[0].events.filter { $0.key == .stream }.map(\.title), ["The model finished request 1", "The model finished request 2"])
    }

    /// The simulator's proof run (dc522572), its second turn, with its requests marked as the
    /// stream marks them: words heard ahead, saved while the guest worked, three model requests with
    /// two tools between them.
    func testTheProofRunsTurnIsReadAsItHappened() throws {
        let tag = "turn=8899060a"
        let lines = [
            line(-350, "turn.pass.done"), line(-350, "turn.attempt.end", "turn=8cd094c9 answered"),
            line(0, "turn.line", tag), line(0, "turn.attempt", tag), line(0, "turn.send"), line(24, "turn.begin"),
            line(50, "turn.guest.write"), line(51, "turn.heard"), line(62, "turn.guest.firstLine"), line(172, "turn.guest.init"),
            line(921, "turn.lease.fresh"), line(921, "turn.person.saved"),
            line(999, "turn.guest.message", "own guest=1 request=1 tokens=14000"), line(1000, "turn.guest.upload", "guest=1 request=1 kind=whole bytes=21000"),
            line(1742, "turn.guest.message.done", "own"), line(1838, "turn.guest.toolUse"), line(4800, "turn.guest.toolResult"),
            line(7826, "turn.guest.message", "own guest=1 request=2 tokens=14600"), line(7827, "turn.guest.upload", "guest=1 request=2 kind=thread bytes=2600"),
            line(8395, "turn.guest.message.done", "own"), line(8440, "turn.guest.toolUse"), line(8900, "turn.guest.toolResult"),
            line(9777, "turn.guest.message", "own guest=1 request=3 tokens=15100"), line(9778, "turn.guest.upload", "guest=1 request=3 kind=thread bytes=2700"),
            line(10594, "turn.text.first"), line(11234, "turn.guest.message.done", "own"), line(12154, "turn.guest.result"),
            line(12718, "turn.reply.saved"), line(12727, "turn.reply.shown", tag), line(14049, "turn.pass.done"),
            line(14049, "turn.attempt.end", "\(tag) answered"),
        ]
        let turn = try XCTUnwrap(timelines(lines).first)
        XCTAssertFalse(turn.mixed)
        XCTAssertEqual(turn.total, 12727)
        XCTAssertEqual(turn.events.map(\.key), [.queue, .ready, .start, .model, .stream, .tool, .model, .stream,
                                                 .tool, .model, .screen, .stream, .finish, .store, .show])
        XCTAssertEqual(turn.events.map(\.took).reduce(0, +), turn.total)
        XCTAssertEqual(turn.events[3].took, 827, "the model's wait for request 1 is its own, not the save's")
        XCTAssertEqual(turn.beside.map(\.took), [921])
        XCTAssertEqual(turn.tools, 2)
        XCTAssertEqual(turn.requestBytes, [21000, 2600, 2700])
        XCTAssertEqual(turn.requestThreads, ["whole", "thread", "thread"])
    }

    /// The `--talk` run's spoken turn, from its real marks: the release, the hearing, the words
    /// heard ahead and saved while the guest worked, and the voice beside the reply.
    func testTheTalkRunsSpokenTurnIsReadAsItHappened() async {
        let tag = "turn=14adda04"
        let lines = [
            line(0, "voice.released"), line(1173, "voice.heard"), line(1214, "turn.line", tag), line(1214, "turn.spoken", tag),
            line(1267, "turn.attempt", tag), line(1267, "turn.send"), line(1284, "turn.guest.write"), line(1284, "turn.heard"),
            line(1316, "turn.guest.firstLine"), line(1744, "turn.guest.init"), line(1802, "turn.lease.acquired"),
            line(2448, "turn.saved"), line(2449, "turn.person.saved"),
            line(3267, "turn.guest.message", "own guest=1 request=1 tokens=48000"), line(3268, "turn.guest.upload", "guest=1 request=1 kind=whole bytes=21500"),
            line(4986, "turn.text.first"), line(4987, "speak.begin", tag), line(5085, "speak.firstFrame"),
            line(5496, "turn.guest.message.done", "own"), line(5505, "speak.firstFrame"), line(5605, "turn.guest.result"),
            line(6115, "turn.reply.saved"), line(6124, "turn.reply.shown", tag), line(7438, "turn.pass.done"),
            line(7438, "turn.attempt.end", "\(tag) answered"), line(7780, "speak.firstFrame"),
        ]
        let reply = await tool(lines).run(["turn", "--tsv"])
        XCTAssertEqual(reply.text.split(separator: "\n").map(String.init), [
            "key\tat_ms\ttook_ms\ttitle",
            "hear\t1173\t1173\tHeard you",
            "queue\t1267\t94\tStarted on its way",
            "ready\t1284\t17\tClaude Code had your words",
            "start\t1744\t460\tClaude Code started on your words",
            "model\t3267\t1523\tRequest 1 sent and the model began answering (21 KB, the whole conversation)",
            "screen\t4986\t1719\tFirst words on your screen",
            "stream\t5496\t510\tThe model finished request 1",
            "finish\t5605\t109\tClaude Code finished the reply",
            "store\t6115\t510\tThe reply saved to iCloud",
            "show\t6124\t9\tThe reply on your screen",
            "save\t1267\t1181\tYour words saved to iCloud, while Claude Code worked",
            "sound\t4987\t98\tThe voice's first sound",
            "record: perf-turn 2027-01-15T08:00:00Z spoken answered total=6124 hear=1173 queue=94 ready=17 start=460 "
                + "model=1523 stream=510 screen=1719 finish=109 store=510 show=9 saved=2448 sound=5085 thread=whole "
                + "bytes=21500 requests=1 tools=0 sends=1",
        ])
    }

    func testTheLastIsTheNewestFinishedTurnNotTheOneAsking() async {
        let lines = typed(at: 0) + typed(at: 10_000, id: "bbbb0000")
            + [line(20_000, "turn.line", "turn=cccc0000"), line(20_001, "turn.attempt", "turn=cccc0000")]
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

    func testNoTurnIsSaidAsSoAndOnlyPerfLinesAreRead() async {
        let cloud = typed(at: 0).map { LogLine(at: $0.at, level: $0.level, category: "cloud", message: $0.message) }
        let none = await tool(cloud).run(["turn"])
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
        ear.load(acoustic: nowhere)
        for _ in 0..<400 where !ear.ready { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ear.ready)
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure,
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
