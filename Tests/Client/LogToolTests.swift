import OSLog
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

    func testTheLastTenMinutesOldestFirstWithLevelCategoryAndTime() async {
        let tool = tool([line(3600, "audio", "an hour ago"), line(599, "audio", "hold taken"),
                         line(30, "tools", "run maps: status 0", level: "info"), line(1, "perf", "mark t=1 turn.sent\nsecond line", level: "error")])
        let reply = await tool.run([])
        XCTAssertEqual(reply, .ok("""
        \(LogTool.stamp(Self.noon.addingTimeInterval(-599))) | notice | audio | hold taken
        \(LogTool.stamp(Self.noon.addingTimeInterval(-30))) | info | tools | run maps: status 0
        \(LogTool.stamp(Self.noon.addingTimeInterval(-1))) | error | perf | mark t=1 turn.sent second line

        """))
        XCTAssertEqual(LogTool.stamp(Self.noon, in: TimeZone(identifier: "America/Los_Angeles")!), "2026-09-26T12:00:00.000-07:00")
    }

    func testSinceCategoryAndGrepEachNarrow() async {
        let tool = tool([line(3000, "audio", "Hold taken"), line(120, "audio", "hold dropped"), line(60, "Tools", "run maps"),
                         line(30, "audio", "keeper started")])
        let hour = await tool.run(["--since", "60"])
        XCTAssertEqual(hour.text.split(separator: "\n").count, 4)
        let audio = await tool.run(["--category", "AUDIO"])
        XCTAssertEqual(audio.text.split(separator: "\n").map { $0.components(separatedBy: " | ").last }, ["hold dropped", "keeper started"])
        let held = await tool.run(["--since", "60", "--grep", "hold"])
        XCTAssertEqual(held.text.split(separator: "\n").map { $0.components(separatedBy: " | ").last }, ["Hold taken", "hold dropped"])
        let both = await tool.run(["--category", "tools", "--grep=--none"])
        XCTAssertEqual(both, .ok("no log lines in the last 10 min\n"))
        let minute = await tool.run(["--since", "1"])
        XCTAssertEqual(minute.text.split(separator: "\n").count, 2)
    }

    func testNoLinesSaysSo() async {
        let reply = await tool([]).run(["--since", "5"])
        XCTAssertEqual(reply, .ok("no log lines in the last 5 min\n"))
    }

    func testRefusesWhatItDoesNotTake() async {
        let tool = tool([line(1, "audio", "x")])
        for arguments in [["tail"], ["--since", "0"], ["--since", "1441"], ["--since", "ten"], ["--since", "1.5"], ["--since", "-5"],
                          ["--since"], ["--category="], ["--grep="], ["--level", "error"], ["--since", "٣"]] {
            let reply = await tool.run(arguments)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(arguments): \(reply.text)")
        }
    }

    func testAStoreThatCannotBeReadIsAFailureInItsWords() async {
        let reply = await LogTool(reader: Failing(), now: { Self.noon }).run([])
        XCTAssertEqual(reply, .failed("topo: the log store is closed\n"))
    }

    /// The answer is at most 24 KB: the newest lines whole, and a first line counting the rest.
    func testTheNewestLinesAreKeptUnderTheBudget() async {
        let lines = (0..<1000).map { line(Double(1000 - $0) / 2, "audio", "line \($0) " + String(repeating: "é", count: 40)) }
        let reply = await tool(lines).run([])
        XCTAssertLessThanOrEqual(reply.text.utf8.count, LogTool.budget)
        let written = reply.text.split(separator: "\n").map(String.init)
        let kept = written.count - 1
        XCTAssertEqual(written.first, "… \(1000 - kept) earlier lines left out, cut at 24 KB; narrow with --since, --category or --grep")
        XCTAssertLessThanOrEqual(written[0].utf8.count + 1, LogTool.firstLineRoom)
        XCTAssertTrue(written.last?.contains("| line 999 ") ?? false, written.last ?? "")
        XCTAssertTrue(written[1].contains("| line \(1000 - kept) "), written[1])
        XCTAssertGreaterThan(kept, 150)
        // One more line would not have fitted.
        XCTAssertGreaterThan(reply.text.utf8.count + written[1].utf8.count + 1, LogTool.budget - LogTool.firstLineRoom)
        let whole = await tool(Array(lines.suffix(10))).run([])
        XCTAssertEqual(whole.text.split(separator: "\n").count, 10)
        XCTAssertFalse(whole.text.hasPrefix("…"))
    }

    /// A line longer than the whole budget is left out and counted, never cut.
    func testALineThatCannotFitIsLeftOut() {
        let huge = String(repeating: "x", count: LogTool.budget)
        XCTAssertEqual(LogTool.fit(["older", huge], none: "none"), "… 2 earlier lines left out, cut at 24 KB; narrow with --since, --category or --grep\n")
        XCTAssertEqual(LogTool.fit([huge, "newest"], none: "none"), "… 1 earlier lines left out, cut at 24 KB; narrow with --since, --category or --grep\nnewest\n")
    }

    @MainActor func testTheToolAsksNoPermissionAndIsInTheTable() async {
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
        XCTAssertTrue(reply.text.hasSuffix("| error | logtest | \(mark) ours\n"), reply.text)
        XCTAssertEqual(reply.text.split(separator: "\n").count, 1)
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
