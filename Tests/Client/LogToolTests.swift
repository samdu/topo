import OSLog
import TopoCore
import TopoTools
import XCTest

@testable import Topo

/// `topo log` (#281): the app's own lines from the unified log, filtered and bounded, over a fake
/// reader; and the real reader over lines this process writes.
final class LogToolTests: XCTestCase {
    private struct Fixed: LogReading {
        var lines: [LogLine]
        func lines(since: Date) throws -> [LogLine] { lines }
    }

    private struct Failing: LogReading {
        struct Refused: Error, LocalizedError { var errorDescription: String? { "the log store is closed" } }
        func lines(since: Date) throws -> [LogLine] { throw Refused() }
    }

    private static let noon = ISO8601DateFormatter().date(from: "2026-09-26T19:00:00Z")!

    private func line(_ secondsAgo: Double, _ category: String, _ message: String, level: String = "notice") -> LogLine {
        LogLine(at: Self.noon.addingTimeInterval(-secondsAgo), level: level, category: category, message: message)
    }

    private func tool(_ lines: [LogLine]) -> LogTool {
        LogTool(reader: Fixed(lines: lines), now: { Self.noon })
    }

    private func cursor(_ secondsAgo: Double, _ count: Int) -> String {
        "cursor: \(LogTool.stamp(Self.noon.addingTimeInterval(-secondsAgo)))#\(count)"
    }

    private func messages(_ reply: ToolReply) -> [String] {
        reply.text.split(separator: "\n").filter { $0.contains(" | ") }.map { String($0.components(separatedBy: " | ").last!) }
    }

    func testTheLastTenMinutesOldestFirstWithLevelCategoryAndTime() async {
        let tool = tool([line(3600, "audio", "an hour ago"), line(599, "audio", "hold taken"),
                         line(30, "tools", "run maps: status 0", level: "info"), line(1, "perf", "mark t=1 turn.sent\nsecond line", level: "error")])
        let reply = await tool.run([])
        XCTAssertEqual(reply, .ok("""
        \(LogTool.stamp(Self.noon.addingTimeInterval(-599))) | notice | audio | hold taken
        \(LogTool.stamp(Self.noon.addingTimeInterval(-30))) | info | tools | run maps: status 0
        \(LogTool.stamp(Self.noon.addingTimeInterval(-1))) | error | perf | mark t=1 turn.sent second line
        \(cursor(30, 1))

        """))
        XCTAssertEqual(LogTool.stamp(Self.noon, in: TimeZone(identifier: "America/Los_Angeles")!), "2026-09-26T12:00:00.000-07:00")
    }

    func testSinceCategoryAndGrepEachNarrow() async {
        let tool = tool([line(3000, "audio", "Hold taken"), line(120, "audio", "hold dropped"), line(60, "Tools", "run maps"),
                         line(30, "audio", "keeper started")])
        let hour = await tool.run(["--since", "60"])
        XCTAssertEqual(messages(hour).count, 4)
        let audio = await tool.run(["--category", "AUDIO"])
        XCTAssertEqual(messages(audio), ["hold dropped", "keeper started"])
        let held = await tool.run(["--since", "60", "--grep", "hold"])
        XCTAssertEqual(messages(held), ["Hold taken", "hold dropped"])
        // The cursor is where the read got to, whatever the filters kept.
        XCTAssertTrue(held.text.hasSuffix(cursor(30, 1) + "\n"), held.text)
        let both = await tool.run(["--category", "tools", "--grep=--none"])
        XCTAssertEqual(both, .ok("no log lines in the last 10 min\n\(cursor(30, 1))\n"))
        let minute = await tool.run(["--since", "1"])
        XCTAssertEqual(messages(minute), ["run maps", "keeper started"])
    }

    func testNoLinesSaysSoWithACursorASecondBeforeNow() async {
        let reply = await tool([]).run(["--since", "5"])
        XCTAssertEqual(reply, .ok("no log lines in the last 5 min\n\(cursor(1, 0))\n"))
    }

    func testRefusesWhatItDoesNotTake() async {
        let tool = tool([line(1, "audio", "x")])
        for arguments in [["tail"], ["--since", "0"], ["--since", "1441"], ["--since", "ten"], ["--since", "1.5"], ["--since", "-5"],
                          ["--since"], ["--category="], ["--grep="], ["--level", "error"], ["--since", "٣"],
                          ["--after="], ["--after", "yesterday"], ["--after", "2026-09-26T19:00:00Z#"], ["--after", "2026-09-26T19:00:00Z#-1"],
                          ["--after", "2026-09-26T19:00:00Z#1#2"], ["--since", "5", "--after", "2026-09-26T19:00:00Z"], ["--for", "5m"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
    }

    func testAStoreThatCannotBeReadIsAFailureInItsWords() async {
        let reply = await LogTool(reader: Failing(), now: { Self.noon }).run([])
        XCTAssertEqual(reply, .failed("topo: the log store is closed\n"))
        let after = await LogTool(reader: Failing(), now: { Self.noon }).run(["--after", "2026-09-26T19:00:00Z"])
        XCTAssertEqual(after, .failed("topo: the log store is closed\n"))
    }

    /// The answer is at most 24 KB: the newest lines whole, a first line counting the rest and
    /// saying where to read them from, and the cursor last.
    func testTheNewestLinesAreKeptUnderTheBudget() async {
        let lines = (0..<1000).map { line(Double(1000 - $0) / 2, "audio", "line \($0) " + String(repeating: "é", count: 40)) }
        let reply = await tool(lines).run([])
        XCTAssertLessThanOrEqual(reply.text.utf8.count, LogTool.budget)
        let written = reply.text.split(separator: "\n").map(String.init)
        let kept = written.count - 2
        XCTAssertEqual(written.first, "… \(1000 - kept) lines left out, cut at 24 KB; read them and those after with --after \(LogTool.stamp(Self.noon.addingTimeInterval(-500)))#0")
        XCTAssertLessThanOrEqual(written[0].utf8.count + 1, LogTool.firstLineRoom)
        XCTAssertTrue(written[written.count - 2].contains("| line 999 "), written[written.count - 2])
        // The newest lines are in the last second or the millisecond at its edge, so the cursor is before them.
        XCTAssertEqual(written.last, cursor(1.5, 1))
        XCTAssertTrue(written[1].contains("| line \(1000 - kept) "), written[1])
        XCTAssertGreaterThan(kept, 150)
        // One more line would not have fitted.
        XCTAssertGreaterThan(reply.text.utf8.count + written[1].utf8.count + 1, LogTool.budget - LogTool.firstLineRoom - LogTool.lastLineRoom)
        let whole = await tool(Array(lines.suffix(10))).run([])
        XCTAssertEqual(whole.text.split(separator: "\n").count, 11)
        XCTAssertFalse(whole.text.hasPrefix("…"))
    }

    /// A line longer than the whole budget is left out and counted, never cut, and costs no
    /// other line its place: the lines either side of it are kept, and a page says so too.
    func testALineThatCannotFitIsLeftOutAlone() async {
        let huge = String(repeating: "x", count: LogTool.budget)
        let tool = tool([line(30, "audio", "older"), line(20, "audio", huge), line(10, "audio", "newest")])
        let reply = await tool.run([])
        XCTAssertEqual(messages(reply), ["older", "newest"])
        XCTAssertTrue(reply.text.hasPrefix("… 1 lines left out, cut at 24 KB; read them and those after with --after \(LogTool.stamp(Self.noon.addingTimeInterval(-30)))#0\n"), reply.text)
        let page = await tool.run(["--after", LogTool.stamp(Self.noon.addingTimeInterval(-60))])
        XCTAssertEqual(messages(page), ["older", "newest"])
        XCTAssertTrue(page.text.hasPrefix("… 1 lines left out, each longer than the 24 KB an answer holds\n"), page.text)
        XCTAssertTrue(page.text.hasSuffix(cursor(10, 1) + "\n"), page.text)
    }

    // MARK: Paging

    /// A loop of --after reads gets every line once: a page full at 24 KB says "more:" with the
    /// cursor to carry on from, and the last page says "cursor:".
    func testAfterPagesEveryLineOnceOldestFirst() async {
        let lines = (0..<1000).map { line(Double(2000 - $0), "audio", "line \($0) " + String(repeating: "é", count: 40)) }
        let tool = tool(lines)
        var after = LogTool.stamp(Self.noon.addingTimeInterval(-3000))
        var seen: [String] = []
        var pages = 0
        while pages < 20 {
            let reply = await tool.run(["--after", after])
            XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
            XCTAssertLessThanOrEqual(reply.text.utf8.count, LogTool.budget)
            pages += 1
            seen += messages(reply).map { String($0.split(separator: " ")[1]) }
            let last = String(reply.text.split(separator: "\n").last!)
            if last.hasPrefix("more: --after ") { after = String(last.dropFirst("more: --after ".count)); continue }
            XCTAssertTrue(last.hasPrefix("cursor: "), last)
            after = String(last.dropFirst("cursor: ".count))
            break
        }
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(seen, (0..<1000).map(String.init))
        let again = await tool.run(["--after", after])
        XCTAssertEqual(again, .ok("no log lines after \(after)\ncursor: \(after)\n"))
    }

    /// Lines in one millisecond are told apart by the count after `#`, so a cursor between two of
    /// them neither repeats the first nor skips the second; a bare time reads after its millisecond.
    func testACursorInsideAMillisecond() async {
        let tool = tool([line(10, "audio", "a"), line(10, "audio", "b"), line(10, "cloud", "c"), line(9.999, "audio", "d")])
        let stamp = LogTool.stamp(Self.noon.addingTimeInterval(-10))
        let first = await tool.run(["--after", stamp + "#1"])
        XCTAssertEqual(messages(first), ["b", "c", "d"])
        let filtered = await tool.run(["--after", stamp + "#0", "--category", "cloud"])
        XCTAssertEqual(messages(filtered), ["c"])
        XCTAssertTrue(filtered.text.hasSuffix(cursor(9.999, 1) + "\n"), filtered.text)
        let bare = await tool.run(["--after", stamp])
        XCTAssertEqual(messages(bare), ["d"])
        // A bare time with nothing after it is said back bare, so the next read does not take its
        // millisecond again.
        let later = LogTool.stamp(Self.noon.addingTimeInterval(-9))
        let empty = await tool.run(["--after", later])
        XCTAssertEqual(empty, .ok("no log lines after \(later)\ncursor: \(later)\n"))
        let utc = await tool.run(["--after", "2026-09-26T18:59:50.000Z#2"])
        XCTAssertEqual(messages(utc), ["c", "d"])
    }

    /// The store dropped the lines a cursor stood among: the page says so rather than reading as
    /// though nothing was missed.
    func testACursorTheStoreNoLongerHoldsSaysLinesWereLost() async {
        let tool = tool([line(5, "audio", "later")])
        let stamp = LogTool.stamp(Self.noon.addingTimeInterval(-10))
        let reply = await tool.run(["--after", stamp + "#3"])
        XCTAssertEqual(reply, .ok("""
        … the store no longer holds the line at \(stamp)#3; lines before this page were lost
        \(LogTool.stamp(Self.noon.addingTimeInterval(-5))) | notice | audio | later
        \(cursor(5, 1))

        """))
    }

    /// A cursor ahead of every line has lost nothing: there is nothing after it yet.
    func testACursorAheadOfTheStoreLostNothing() async {
        let tool = tool([line(5, "audio", "earlier")])
        let stamp = LogTool.stamp(Self.noon.addingTimeInterval(-3))
        let reply = await tool.run(["--after", stamp + "#4"])
        XCTAssertEqual(reply, .ok("no log lines after \(stamp)#4\ncursor: \(stamp)#4\n"))
    }

    /// --since's cursor is before the last second, as a page's is: a line of that second is shown
    /// and comes again at the next --after, rather than one still on its way being passed over.
    func testSincesCursorStopsShortOfTheLastSecond() async {
        let tool = tool([line(5, "audio", "settled"), line(0.5, "audio", "fresh")])
        let reply = await tool.run([])
        XCTAssertEqual(messages(reply), ["settled", "fresh"])
        XCTAssertTrue(reply.text.hasSuffix(cursor(5, 1) + "\n"), reply.text)
    }

    /// A store whose lines change between reads, read at a clock the test moves.
    private final class Arriving: LogReading, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [LogLine] = []
        var at = Date()
        func set(_ lines: [LogLine], at: Date) { lock.withLock { held = lines; self.at = at } }
        func now() -> Date { lock.withLock { at } }
        func lines(since: Date) throws -> [LogLine] { lock.withLock { held } }
    }

    /// The millisecond the settle's edge falls in is held back whole. A line of it read while a
    /// line stamped earlier in that same millisecond is still on its way would otherwise be
    /// counted as the first, and the late one skipped while the counted one came again.
    func testTheMillisecondAtTheSettlesEdgeIsHeldBackWhole() async {
        let store = Arriving()
        let tool = LogTool(reader: store, now: { store.now() })
        let edge = Self.noon.addingTimeInterval(-1)
        let late = LogLine(at: edge.addingTimeInterval(0.0008), level: "notice", category: "audio", message: "late")
        let early = LogLine(at: edge.addingTimeInterval(0.0009), level: "notice", category: "audio", message: "early")
        let before = line(5, "audio", "before")
        // At 0.1 ms past noon the edge is in the millisecond both lines are stamped in, and only
        // the second has reached the store.
        store.set([before, early], at: Self.noon.addingTimeInterval(0.0001))
        let first = await tool.run(["--after", LogTool.stamp(Self.noon.addingTimeInterval(-60))])
        XCTAssertEqual(messages(first), ["before"])
        let cursor = String(first.text.split(separator: "\n").last!.dropFirst("cursor: ".count))
        XCTAssertEqual(cursor, LogTool.stamp(Self.noon.addingTimeInterval(-5)) + "#1")
        store.set([before, late, early], at: Self.noon.addingTimeInterval(5))
        let second = await tool.run(["--after", cursor])
        XCTAssertEqual(messages(second), ["late", "early"])
        // --since stops its cursor short of the same millisecond.
        store.set([before, early], at: Self.noon.addingTimeInterval(0.0001))
        let since = await tool.run([])
        XCTAssertTrue(since.text.hasSuffix(self.cursor(5, 1) + "\n"), since.text)
    }

    /// A time written finer than a millisecond is in the millisecond it falls in, not the next:
    /// a line later in that millisecond is still after it. One written to the millisecond is
    /// that millisecond exactly.
    func testATimeFinerThanAMillisecondIsTheMillisecondItFallsIn() async {
        let base = ISO8601DateFormatter().date(from: "2026-09-26T18:59:50Z")!
        let ms = LogTool.ms(base) + 123
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50.1239Z"), LogTool.Cursor(ms: ms, count: nil))
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50.1239995Z"), LogTool.Cursor(ms: ms, count: nil))
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50.999999999Z"), LogTool.Cursor(ms: ms + 876, count: nil))
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50.123Z"), LogTool.Cursor(ms: ms, count: nil))
        XCTAssertEqual(LogTool.cursor("2026-09-26T11:59:50.1-07:00"), LogTool.Cursor(ms: ms - 23, count: nil))
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50Z"), LogTool.Cursor(ms: ms - 123, count: nil))
        XCTAssertNil(LogTool.cursor("2026-09-26T18:59:50.Z"))
        XCTAssertEqual(LogTool.cursor("2026-09-26T18:59:50.123Z#2"), LogTool.Cursor(ms: ms, count: 2))
    }

    /// A paged read holds back the last second, which a line can still be on its way to the
    /// store in: the next read has it.
    func testAPageHoldsBackTheLastSecond() async {
        let tool = tool([line(2, "audio", "settled"), line(0.5, "audio", "arriving")])
        let reply = await tool.run(["--after", LogTool.stamp(Self.noon.addingTimeInterval(-60))])
        XCTAssertEqual(messages(reply), ["settled"])
        XCTAssertTrue(reply.text.hasSuffix(cursor(2, 1) + "\n"), reply.text)
    }

    /// A stamp is the millisecond the line falls in, never rounded up into the next, and a
    /// cursor said reads back as the same place.
    func testAStampIsItsMillisecondAndACursorRoundTrips() {
        let late = Date(timeIntervalSince1970: 1_790_000_000.123_999)
        XCTAssertEqual(LogTool.stamp(late, in: TimeZone(identifier: "UTC")!), "2026-09-21T14:13:20.123Z")
        for ms in stride(from: Int64(1_790_000_000_000), to: 1_790_000_001_000, by: 7) {
            let cursor = LogTool.Cursor(ms: ms, count: 3)
            XCTAssertEqual(LogTool.cursor(LogTool.say(cursor)), cursor)
        }
    }

    // MARK: Levels

    func testLevelListsEveryCategoryAndSetsOneForATime() async {
        let levels = LogLevels(now: { Self.noon }, expired: { _, _ in })
        let tool = LogTool(reader: Fixed(lines: []), levels: levels, now: { Self.noon })
        let listed = await tool.run(["level"])
        XCTAssertEqual(listed, .ok(LogCategory.allCases.map { "\($0.rawValue) | default" }.joined(separator: "\n") + "\n"))
        let set = await tool.run(["level", "Cloud", "debug"])
        XCTAssertEqual(set, .ok("cloud | debug | until \(LogTool.stamp(Self.noon.addingTimeInterval(30 * 60)))\n"))
        let off = await tool.run(["level", "audio", "off", "--for", "2h"])
        XCTAssertEqual(off, .ok("audio | off | until \(LogTool.stamp(Self.noon.addingTimeInterval(2 * 3600)))\n"))
        XCTAssertEqual(levels.level(.audio), .off)
        let back = await tool.run(["level", "audio", "default"])
        XCTAssertEqual(back, .ok("audio | default\n"))
        let again = await tool.run(["level"])
        XCTAssertTrue(again.text.contains("cloud | debug | until "), again.text)
        XCTAssertTrue(again.text.contains("audio | default\n"), again.text)
    }

    func testLevelRefusesWhatItDoesNotTakeInWordsOfItsOwn() async {
        let tool = LogTool(reader: Fixed(lines: []), levels: LogLevels(now: { Self.noon }), now: { Self.noon })
        let cases: [([String], String)] = [
            (["level", "radio", "debug"], "no category radio; the categories are "),
            (["level", "audio", "loud"], "a level is debug, default or off"),
            (["level", "audio"], "level takes a category and a level"),
            (["level", "audio", "debug", "now"], "level takes a category and a level"),
            (["level", "audio", "debug", "--for", "3h"], "--for takes minutes or hours"),
            (["level", "audio", "debug", "--for", "30"], "--for takes minutes or hours"),
            (["level", "audio", "debug", "--for", "0m"], "--for takes minutes or hours"),
            (["level", "audio", "debug", "--for", "121m"], "--for takes minutes or hours"),
            (["level", "audio", "default", "--for", "5m"], "default takes no --for"),
            (["level", "--for", "5m"], "--for needs a category and a level"),
            (["level", "audio", "debug", "--since", "5"], "level takes no --since"),
        ]
        for (arguments, said) in cases {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
            XCTAssertTrue(reply.text.hasPrefix("topo: \(said)"), "\(arguments): \(reply.text)")
        }
        XCTAssertEqual(LogTool.duration("120m"), 7200)
        XCTAssertEqual(LogTool.duration("1m"), 60)
    }

    @MainActor func testTheToolIsInTheTableWithItsUsage() async {
        let table = ToolTable([tool([])])
        XCTAssertTrue(table.help.contains("log  the Topo app's own log lines"), table.help)
        let usage = await table.run(["help", "log"])
        XCTAssertTrue(usage.text.contains("topo log [--since MINUTES] [--category NAME] [--grep TEXT]"), usage.text)
        XCTAssertNotNil(GuestResident.shared.toolTable.first { $0 is LogTool }, "the app's table has no log tool")
    }

    // MARK: The unified log itself

    /// The real reader finds a line this process wrote under the app's subsystem, with its level
    /// and category, and no line of another subsystem.
    func testTheReaderFindsThisProcessesOwnLinesAndNoOtherSubsystems() async throws {
        let mark = "log-tool-\(UUID().uuidString)"
        let started = Date().addingTimeInterval(-1)
        Logger(subsystem: "zone.hexagon.topo", category: "logtest").error("\(mark, privacy: .public) ours")
        Logger(subsystem: "zone.hexagon.other", category: "logtest").error("\(mark, privacy: .public) theirs")
        let lines = try UnifiedLogReader().lines(since: started).filter { $0.message.contains(mark) }
        XCTAssertEqual(lines.map(\.message), ["\(mark) ours"])
        XCTAssertEqual(lines.first?.level, "error")
        XCTAssertEqual(lines.first?.category, "logtest")

        let reply = await LogTool(reader: UnifiedLogReader()).run(["--since", "1", "--category", "logtest", "--grep", mark])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let said = reply.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(said.count, 2, reply.text)
        XCTAssertTrue(said[0].hasSuffix("| error | logtest | \(mark) ours"), reply.text)
        XCTAssertTrue(said[1].hasPrefix("cursor: "), reply.text)
    }

    /// Against the process's own store: lines written in a burst, many in one millisecond, read
    /// back by a loop of --after reads from a cursor before them, each once and in order.
    func testALoopOfAfterReadsOverTheStoreKeepsEveryLineOnce() async throws {
        let mark = "log-loop-\(UUID().uuidString)"
        let log = TopoLog(.cloud)
        log.error("\(mark) fence")
        let fence = try XCTUnwrap(try read(since: .distantPast) { $0.message == "\(mark) fence" }, "the fence never reached the store")
        for index in 0..<200 { log.error("\(mark) \(index)") }
        let tool = LogTool(reader: UnifiedLogReader())
        var after = LogTool.say(LogTool.Cursor(ms: LogTool.ms(fence.at), count: 0))
        var seen: [String] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while seen.count < 201, ContinuousClock.now < deadline {
            let reply = await tool.run(["--after", after, "--grep", mark])
            XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
            seen += reply.text.split(separator: "\n").filter { $0.contains(" | ") }.map { String($0.components(separatedBy: " | ").last!) }
            let last = String(reply.text.split(separator: "\n").last!)
            after = String(last.drop { $0 != " " }.dropFirst()).replacingOccurrences(of: "--after ", with: "")
            if seen.count < 201 { try await Task.sleep(for: .milliseconds(300)) }
        }
        XCTAssertEqual(seen, ["\(mark) fence"] + (0..<200).map { "\(mark) \($0)" })
    }

    /// The read is of the window asked for, not of the launch: lines written before `since` are
    /// not among what the reader hands back, so a long launch is not a long read.
    func testTheReaderReadsOnlyTheWindow() throws {
        let mark = "log-window-\(UUID().uuidString)"
        let logger = Logger(subsystem: "zone.hexagon.topo", category: "logtest")
        for index in 0..<300 { logger.error("\(mark, privacy: .public) before \(index, privacy: .public)") }
        Thread.sleep(forTimeInterval: 1.5)
        // The store stamps a line from its own time base, which `Date()` leaves as the host's
        // clock is slewed, by an amount that grows over the process's life. So the window opens
        // at a fence line's own stamp, read back from the store, never at a `Date()`: the lines
        // before are a second and a half before it on the store's clock whatever the host's says.
        logger.error("\(mark, privacy: .public) fence")
        let fence = try XCTUnwrap(try read(since: .distantPast) { $0.message == "\(mark) fence" }, "the fence never reached the store")
        let since = fence.at
        logger.error("\(mark, privacy: .public) after")
        // A line is in the store a moment after it is written, and later on a busy Mac.
        _ = try read(since: since) { $0.message == "\(mark) after" }
        let lines = try UnifiedLogReader().lines(since: since)
        // The fence is at the window's very start, which the store's comparison may or may not
        // count as inside it; what matters is that no line before it is.
        XCTAssertEqual(lines.filter { $0.message.contains(mark) && $0.message != "\(mark) fence" }.map(\.message), ["\(mark) after"])
        XCTAssertLessThan(lines.count, 100, "the read went back past its window")
        XCTAssertTrue(lines.allSatisfy { $0.at >= since })
    }

    /// The first line read at `since` that `matches`, read again until it is there, with no read
    /// begun more than 5 s after the first on a clock no correction of the host's moves. A read
    /// itself is not cut short, so one slow read can end the wait later than that.
    private func read(since: Date, _ matches: (LogLine) -> Bool) throws -> LogLine? {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if let line = try UnifiedLogReader().lines(since: since).first(where: matches) { return line }
            Thread.sleep(forTimeInterval: 0.1)
        } while ContinuousClock.now < deadline
        return nil
    }

    /// The resident's own lines, the proxy's and the tool service's among them, are in the unified
    /// log under `resident` in every build, with a credential in one hidden: a trip to the
    /// background that went wrong is what `topo log` is for.
    func testTheResidentsLinesAreReadableAndHoldNoCredential() async throws {
        let mark = "log-resident-\(UUID().uuidString)"
        GuestResident.log("background: \(mark) ended; Claude Code exited: CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-SENTINEL Bearer abc.def ops_SENTINEL")
        GuestResident.log("proxy: \(mark) POST /v1/messages 200 in 1.2 s")
        let reply = await LogTool(reader: UnifiedLogReader()).run(["--since", "1", "--category", "resident", "--grep", mark])
        XCTAssertEqual(reply.status, ToolReply.ok, reply.text)
        let lines = reply.text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("cursor: ") }
        XCTAssertEqual(lines.count, 2, reply.text)
        XCTAssertTrue(lines[0].hasSuffix("| info | resident | background: \(mark) ended; Claude Code exited: CLAUDE_CODE_OAUTH_TOKEN=[redacted] Bearer [redacted] ops_[redacted]"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("| info | resident | proxy: \(mark) POST /v1/messages 200 in 1.2 s"), lines[1])
        XCTAssertFalse(reply.text.contains("SENTINEL"))
    }

    /// A value logged `privacy: .private` is not private from this process's own store: it reads
    /// back whole, so `topo log` would answer it. Nothing redacts a line for the tool; what keeps
    /// a secret out of an answer is that the app logs none.
    func testAPrivateValueIsNotPrivateFromTheProcessesOwnStore() throws {
        let mark = "log-private-\(UUID().uuidString)"
        let secret = "SENTINEL-\(UUID().uuidString)"
        let started = Date().addingTimeInterval(-1)
        Logger(subsystem: "zone.hexagon.topo", category: "logtest").error("\(mark, privacy: .public) \(secret, privacy: .private)")
        let lines = try UnifiedLogReader().lines(since: started).filter { $0.message.contains(mark) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.message, "\(mark) \(secret)")
    }
}
