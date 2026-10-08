import Foundation
import OSLog
import TopoTools

/// One line the app wrote to the unified log.
struct LogLine: Sendable, Equatable {
    var at: Date
    /// `debug`, `info`, `notice`, `error` or `fault`.
    var level: String
    var category: String
    var message: String
}

/// The app's own lines in the unified log: `OSLogStore` on the phone, a fake in the suites.
protocol LogReading: Sendable {
    /// Every line since `since`, oldest first.
    func lines(since: Date) throws -> [LogLine]
}

/// `topo log`: what the app itself wrote to the unified log, so a stall or a red banner the person
/// reports can be looked at from inside. Read only, and only this process's lines under the app's
/// own subsystem: nothing another process or a system framework logged.
struct LogTool: Tool {
    let reader: any LogReading
    var now: @Sendable () -> Date = { Date() }

    static let defaultMinutes = 10
    static let minutes = 1...1440
    /// The most an answer holds, in bytes, and the room kept in it for the line that says what was
    /// left out.
    static let budget = 24 * 1024
    static let firstLineRoom = 160

    let name = "log"
    let summary = "the Topo app's own log lines, to see what it did"
    let usage = """
    topo log [--since MINUTES] [--category NAME] [--grep TEXT]
                                        the app's own log lines from the last MINUTES (10 unless given, 1 to 1440),
                                        oldest first: time | level | category | message

    --category keeps one category (resident, audio, perf, dns, models) and --grep the lines whose
    message holds TEXT, whatever its case. resident is the guest's own running: its starts and exits,
    each trip to the background, and the API proxy's and the tool service's lines, which start
    "proxy:" and "tools:". The lines are this launch's only, since the app reads
    them from its own process, and the widgets' and controls' are not among them: those run in
    processes of their own. An answer is at most 24 KB, the newest lines kept; a first line
    starting "…" says how many earlier ones were left out.
    """

    struct Call: Equatable {
        var minutes: Int
        var category: String?
        var grep: String?
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run({ _ in nil }, broker: PermissionBroker(), usage: usage, parse: { try parse(arguments) }) { call in
            let since = now().addingTimeInterval(-Double(call.minutes) * 60)
            let reader = reader
            // The store's read blocks, so it has a thread of its own and never one of the pool's.
            let read: [LogLine] = try await withCheckedThrowingContinuation { continuation in
                Self.queue.async { continuation.resume(with: Result { try reader.lines(since: since) }) }
            }
            try Task.checkCancellation()
            let kept = read.filter { line in
                line.at >= since
                    && (call.category.map { line.category.compare($0, options: [.caseInsensitive]) == .orderedSame } ?? true)
                    && (call.grep.map { line.message.range(of: $0, options: [.caseInsensitive]) != nil } ?? true)
            }
            return .ok(Self.fit(kept.map(Self.line), none: "no log lines in the last \(call.minutes) min"))
        }
    }

    private static let queue = DispatchQueue(label: "zone.hexagon.topo.log-read")

    func parse(_ arguments: [String]) throws -> Call {
        let read = try Arguments(arguments, options: ["since", "category", "grep"])
        guard read.words.isEmpty else { throw Misuse("log takes no \(read.words[0])") }
        var minutes = Self.defaultMinutes
        if let text = read.options["since"] {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), Self.minutes.contains(value) else {
                throw Misuse("--since takes a whole number of minutes from \(Self.minutes.lowerBound) to \(Self.minutes.upperBound)")
            }
            minutes = value
        }
        for option in ["category", "grep"] where read.options[option]?.isEmpty == true {
            throw Misuse("--\(option) needs a value")
        }
        return Call(minutes: minutes, category: read.options["category"], grep: read.options["grep"])
    }

    static func line(_ line: LogLine) -> String {
        PhoneTool.line([stamp(line.at), line.level, line.category, line.message])
    }

    /// A moment to the millisecond, with the phone's offset.
    static func stamp(_ date: Date, in zone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon,
                                                timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: zone))
    }

    /// The newest lines that fit the budget, whole and oldest first, under a first line counting
    /// the earlier ones left out. A line too long to fit alone is left out and counted too.
    static func fit(_ lines: [String], none: String) -> String {
        guard !lines.isEmpty else { return none + "\n" }
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            guard bytes + size <= budget - firstLineRoom else { break }
            kept.append(line)
            bytes += size
        }
        let left = lines.count - kept.count
        let first = left > 0 ? ["… \(left) earlier lines left out, cut at 24 KB; narrow with --since, --category or --grep"] : []
        return (first + kept.reversed()).joined(separator: "\n") + "\n"
    }
}

/// The unified log's own store, scoped to this process, read for the app's subsystem.
struct UnifiedLogReader: LogReading {
    var subsystem = "zone.hexagon.topo"

    func lines(since: Date) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // The date is in the predicate because a store of this scope takes no position: without
        // it every line of the launch is read, and the read is as long as the launch.
        let entries = try store.getEntries(at: store.position(date: since),
                                           matching: NSPredicate(format: "subsystem == %@ AND date >= %@", subsystem, since as NSDate))
        return entries.compactMap { entry in
            guard let entry = entry as? OSLogEntryLog, entry.subsystem == subsystem else { return nil }
            return LogLine(at: entry.date, level: Self.name(entry.level), category: entry.category, message: entry.composedMessage)
        }
    }

    static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }
}
