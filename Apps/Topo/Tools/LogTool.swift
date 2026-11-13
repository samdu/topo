import Foundation
import OSLog
import TopoCore
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
/// own subsystem: nothing another process or a system framework logged. `topo log level` sets
/// how much each category writes, for a time (`LogLevels`).
struct LogTool: Tool {
    let reader: any LogReading
    var levels: LogLevels = .shared
    var now: @Sendable () -> Date = { Date() }

    static let defaultMinutes = 10
    static let minutes = 1...1440
    /// The most an answer holds, in bytes, and the room kept in it for the lines that say what
    /// was left out and where the answer got to.
    static let budget = 24 * 1024
    static let firstLineRoom = 320
    static let lastLineRoom = 100
    /// How long a line is given to reach the store: a paged read stops this far short of now, so
    /// a line stamped before its cursor and stored after it is not skipped.
    static let settle: TimeInterval = 1

    let name = "log"
    let summary = "the Topo app's own log lines, to see what it did, and how much each part logs"
    let usage = """
    topo log [--since MINUTES] [--category NAME] [--grep TEXT]
                                        the app's own log lines from the last MINUTES (10 unless given, 1 to 1440),
                                        oldest first: time | level | category | message
    topo log --after CURSOR [--category NAME] [--grep TEXT]
                                        the lines after CURSOR, oldest first, a page of at most 24 KB
    topo log level                      each category's level, and when one set for a time ends
    topo log level CATEGORY debug|default|off [--for 30m]
                                        sets a category's level: debug adds its detail lines, off
                                        keeps its error lines alone; debug lasts 30m unless given
                                        and never past 2h, off lasts this launch unless given a
                                        time, and no level outlasts the launch

    An answer of lines ends with "cursor: TIME#N", where it got to: every line before TIME's
    millisecond and N lines in it are read. --after takes that cursor, or a bare ISO time to read the
    lines after its millisecond; a page that stopped short ends "more: --after CURSOR" instead, and so
    a loop of --after reads keeps every line once, with the last second's lines held back until they
    have settled. --since shows the newest lines that fit, the last second's among them, and its
    cursor is before that second, so those lines come again in the next --after. "… the store no
    longer holds" says lines before the page were lost.

    The categories are \(LogCategory.allCases.map(\.rawValue).joined(separator: ", ")). cloud is iCloud's: each
    call that failed, with its mapped case and CloudKit's code, and the chat's failure line put up and
    taken down; at debug, every call with its time and the records it named. A failed call is an error
    line, which off keeps. resident is the guest's own
    running: its starts and exits and each trip to the background. --category keeps one category
    and --grep the lines whose message holds TEXT, whatever its case. The lines are this launch's
    only, since the app reads them from its own process, and the widgets' and controls' are not
    among them: those run in processes of their own. A detail line carries no mark of its own: it is
    written at notice, and is one that appears only while its category is at debug. No line holds
    what was said, a secret or a token.
    """

    enum Call: Equatable {
        case lines(Lines)
        case levels
        case set(LogCategory, LogLevel, TimeInterval?)
    }

    struct Lines: Equatable {
        var minutes: Int
        var after: Cursor?
        var category: String?
        var grep: String?
    }

    /// A place in this launch's lines: `count` of the lines stamped in millisecond `ms` are read,
    /// and every line stamped before it. A bare time has read every line of its millisecond.
    struct Cursor: Equatable {
        var ms: Int64
        var count: Int?
    }

    func run(_ arguments: [String]) async -> ToolReply {
        await PhoneTool.run({ _ in nil }, broker: PermissionBroker(), usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case .levels:
                return .ok(LogCategory.allCases.map { describe($0, levels.setting($0)) }.joined(separator: "\n") + "\n")
            case .set(let category, let level, let duration):
                return .ok(describe(category, levels.set(category, level, for: duration)) + "\n")
            case .lines(let call):
                return try await lines(call)
            }
        }
    }

    private func describe(_ category: LogCategory, _ setting: LogLevels.Setting) -> String {
        PhoneTool.line([category.rawValue, setting.level.rawValue, setting.until.map { "until \(Self.stamp($0))" }])
    }

    private func lines(_ call: Lines) async throws -> ToolReply {
        let at = now()
        // A paged read starts a millisecond before its cursor's, so a stamp's float can put no line
        // of that millisecond outside it and every line there is counted from the first.
        let since = call.after.map { Date(timeIntervalSince1970: Double($0.ms) / 1000) }
            ?? at.addingTimeInterval(-Double(call.minutes) * 60)
        // The read starts a millisecond before the one `since` falls in, so every line of that
        // millisecond is counted from its first.
        let from = Date(timeIntervalSince1970: Double(Self.ms(since) - 1) / 1000)
        let reader = reader
        // The store's read blocks, so it has a thread of its own and never one of the pool's.
        let read: [LogLine] = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try reader.lines(since: from) }) }
        }
        try Task.checkCancellation()
        let placed = Self.place(read)
        func keeps(_ line: LogLine) -> Bool {
            (call.category.map { line.category.compare($0, options: [.caseInsensitive]) == .orderedSame } ?? true)
                && (call.grep.map { line.message.range(of: $0, options: [.caseInsensitive]) != nil } ?? true)
        }
        // The millisecond the second's edge falls in is held back whole: a line of it may still be
        // on its way, and a millisecond is counted only once every line of it has settled.
        let settled = Self.ms(at.addingTimeInterval(-Self.settle))
        guard let after = call.after else {
            let window = placed.filter { $0.line.at >= since }
            // The cursor stops short of the last second, as a page does: a line still on its way to
            // the store comes again at the next --after rather than being passed over.
            let end = window.last { $0.ms < settled }.map { Cursor(ms: $0.ms, count: $0.index) }
                ?? Self.cursor(max(since, at.addingTimeInterval(-Self.settle)))
            return .ok(Self.fit(window.filter { keeps($0.line) }, none: "no log lines in the last \(call.minutes) min", end: end))
        }
        let unread = placed.filter { after.precedes($0) && $0.ms < settled }
        // Lost only when the store has gone on past the cursor without the lines it counted: a
        // cursor in the future has nothing after it yet, and nothing was lost.
        let lost = after.count.map { count in
            count > 0 && !placed.contains { $0.ms == after.ms && $0.index >= count } && placed.contains { $0.ms > after.ms }
        } ?? false
        return .ok(Self.page(unread, keeping: keeps, from: after, lost: lost))
    }

    private static let queue = DispatchQueue(label: "zone.hexagon.topo.log-read")

    func parse(_ arguments: [String]) throws -> Call {
        let read = try Arguments(arguments, options: ["since", "after", "category", "grep", "for"])
        if read.words.first == "level" { return try parseLevel(read) }
        guard read.words.isEmpty else { throw Misuse("log takes no \(read.words[0])") }
        guard read.options["for"] == nil else { throw Misuse("--for is level's") }
        var minutes = Self.defaultMinutes
        if let text = read.options["since"] {
            guard read.options["after"] == nil else { throw Misuse("--since and --after do not go together") }
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), Self.minutes.contains(value) else {
                throw Misuse("--since takes a whole number of minutes from \(Self.minutes.lowerBound) to \(Self.minutes.upperBound)")
            }
            minutes = value
        }
        for option in ["category", "grep", "after"] where read.options[option]?.isEmpty == true {
            throw Misuse("--\(option) needs a value")
        }
        let after = try read.options["after"].map { text in
            guard let cursor = Self.cursor(text) else { throw Misuse("--after takes a cursor like 2026-11-04T22:50:00.123-08:00#2, or an ISO time") }
            return cursor
        }
        return .lines(Lines(minutes: minutes, after: after, category: read.options["category"], grep: read.options["grep"]))
    }

    private func parseLevel(_ read: Arguments) throws -> Call {
        for option in ["since", "after", "category", "grep"] where read.options[option] != nil {
            throw Misuse("level takes no --\(option)")
        }
        let words = read.words.dropFirst()
        if words.isEmpty {
            guard read.options["for"] == nil else { throw Misuse("--for needs a category and a level") }
            return .levels
        }
        guard words.count == 2 else { throw Misuse("level takes a category and a level, or nothing to list them") }
        let names = LogCategory.allCases.map(\.rawValue).joined(separator: ", ")
        guard let category = LogCategory(rawValue: words.first!.lowercased()) else {
            throw Misuse("no category \(words.first!); the categories are \(names)")
        }
        guard let level = LogLevel(rawValue: words.last!.lowercased()) else { throw Misuse("a level is debug, default or off") }
        guard let text = read.options["for"] else { return .set(category, level, nil) }
        guard level != .default else { throw Misuse("default takes no --for: it is where every level ends") }
        guard let duration = Self.duration(text) else {
            throw Misuse("--for takes minutes or hours, like 30m or 2h, from 1m to \(Int(LogLevels.longest / 3600))h")
        }
        return .set(category, level, duration)
    }

    /// `30m` or `2h` as seconds, within what a level may be given.
    static func duration(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let scale: TimeInterval = ["m": 60, "h": 3600][unit] else { return nil }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(digits) else { return nil }
        let seconds = TimeInterval(count) * scale
        return (60...LogLevels.longest).contains(seconds) ? seconds : nil
    }

    // MARK: Places

    /// A line and its place: its millisecond and how many lines of that millisecond it ends.
    struct Placed {
        var line: LogLine
        var ms: Int64
        var index: Int
    }

    static func place(_ lines: [LogLine]) -> [Placed] {
        var placed: [Placed] = []
        placed.reserveCapacity(lines.count)
        for line in lines {
            let ms = ms(line.at)
            let index = placed.last.map { $0.ms == ms ? $0.index + 1 : 1 } ?? 1
            placed.append(Placed(line: line, ms: ms, index: index))
        }
        return placed
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func cursor(_ date: Date) -> Cursor { Cursor(ms: ms(date), count: 0) }

    static func cursor(_ text: String) -> Cursor? {
        let parts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let time = String(parts[0])
        // The millisecond the time falls in, read off its digits: the first three of the fraction,
        // whatever follows them, so a finer time is never rounded into the next millisecond.
        var whole = time, fraction = ""
        if let dot = time.firstIndex(of: ".") {
            let digits = time[time.index(after: dot)...].prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty else { return nil }
            fraction = String(digits)
            whole = String(time[..<dot]) + String(time[digits.endIndex...])
        }
        guard let date = try? Date.ISO8601FormatStyle().parse(whole) else { return nil }
        let ms = Int64(date.timeIntervalSince1970.rounded()) * 1000 + Int64(String((fraction + "000").prefix(3)))!
        guard parts.count == 2 else { return Cursor(ms: ms, count: nil) }
        let digits = parts[1]
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(digits) else { return nil }
        return Cursor(ms: ms, count: count)
    }

    /// A cursor as it is written: a bare time, which has read its whole millisecond, says so again.
    static func say(_ cursor: Cursor) -> String {
        let time = stamp(Date(timeIntervalSince1970: Double(cursor.ms) / 1000))
        return cursor.count.map { "\(time)#\($0)" } ?? time
    }

    static func line(_ line: LogLine) -> String {
        PhoneTool.line([stamp(line.at), line.level, line.category, line.message])
    }

    /// A moment to the millisecond it falls in, never rounded up into the next, with the phone's offset.
    static func stamp(_ date: Date, in zone: TimeZone = .current) -> String {
        let ms = ms(date)
        let seconds = Date(timeIntervalSince1970: Double(ms / 1000))
        let whole = seconds.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon,
                                                              timeZoneSeparator: .colon, includingFractionalSeconds: false, timeZone: zone))
        return String(whole.prefix(19)) + "." + String(format: "%03d", Int(ms % 1000)) + String(whole.dropFirst(19))
    }

    /// The newest lines that fit the budget, whole and oldest first, under a first line counting
    /// the ones left out, and over a last line with the cursor. A line too long to fit alone is
    /// left out and counted, and costs no other line its place: the lines before it are kept as
    /// far as the budget goes.
    static func fit(_ lines: [Placed], none: String, end: Cursor) -> String {
        let last = "cursor: \(say(end))"
        guard !lines.isEmpty else { return none + "\n" + last + "\n" }
        let room = budget - firstLineRoom - lastLineRoom
        var kept: [String] = []
        var bytes = 0
        for placed in lines.reversed() {
            let line = Self.line(placed.line)
            let size = line.utf8.count + 1
            if size > room { continue }
            guard bytes + size <= room else { break }
            kept.append(line)
            bytes += size
        }
        let left = lines.count - kept.count
        var first: [String] = []
        if left > 0 {
            // The place before the oldest line left out, so --after reads from it on.
            let from = lines[0]
            first = ["… \(left) lines left out, cut at 24 KB; read them and those after with --after \(say(Cursor(ms: from.ms, count: from.index - 1)))"]
        }
        return (first + kept.reversed() + [last]).joined(separator: "\n") + "\n"
    }

    /// The oldest of `unread` that `keeping` keeps, as many as fit the budget, then the cursor at
    /// the last line looked at: the last one kept when the page is full, the last one read when not.
    static func page(_ unread: [Placed], keeping: (LogLine) -> Bool, from: Cursor, lost: Bool) -> String {
        let room = budget - firstLineRoom - lastLineRoom
        var kept: [String] = []
        var bytes = 0
        var end = from
        var full = false
        var skipped = 0
        for placed in unread {
            if keeping(placed.line) {
                let line = Self.line(placed.line)
                let size = line.utf8.count + 1
                if size > room {
                    skipped += 1
                } else if bytes + size > room {
                    full = true
                    break
                } else {
                    kept.append(line)
                    bytes += size
                }
            }
            end = Cursor(ms: placed.ms, count: placed.index)
        }
        var first: [String] = []
        if lost { first.append("… the store no longer holds the line at \(say(from)); lines before this page were lost") }
        if skipped > 0 { first.append("… \(skipped) lines left out, each longer than the 24 KB an answer holds") }
        if kept.isEmpty, !full { first.append("no log lines after \(say(from))") }
        let last = full ? "more: --after \(say(end))" : "cursor: \(say(end))"
        return (first + kept + [last]).joined(separator: "\n") + "\n"
    }
}

extension LogTool.Cursor {
    /// True when `placed` is after this place.
    func precedes(_ placed: LogTool.Placed) -> Bool {
        placed.ms > ms || (placed.ms == ms && count.map { placed.index > $0 } == true)
    }
}

/// The unified log's own store, scoped to this process, read for the app's subsystem.
struct UnifiedLogReader: LogReading {
    var subsystem = TopoLog.subsystem

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
