import Foundation

/// A tool's arguments split into the words and the options: `--name value` and `--flag`. An
/// option the tool does not take, or one missing its value, is a usage error rather than a word.
/// The value after an option never starts with two dashes: `--notes --done` is `--notes` missing
/// its value, and a value that does start so is written `--notes=--done`.
public struct Arguments: Sendable, Equatable {
    public var words: [String] = []
    public var options: [String: String] = [:]
    public var flags: Set<String> = []

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        /// An option the tool takes, given to a form of it that does not: the option, the form.
        case notTaken(String, by: String)

        public var description: String {
            switch self {
            case .unknown(let option): "no option \(option)"
            case .missingValue(let option): "\(option) needs a value"
            case .notTaken(let option, let form): "\(form) takes no \(option)"
            }
        }
    }

    /// `options` take a value, `flags` do not; both are named without their dashes. `--` ends the
    /// options, so a word can start with a dash.
    public init(_ arguments: [String], options: Set<String> = [], flags: Set<String> = []) throws {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--" {
                words += rest
                break
            }
            guard Self.isOption(argument) else {
                words.append(argument)
                continue
            }
            var name = String(argument.dropFirst(2))
            var inline: String?
            if let equals = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if flags.contains(name), inline == nil {
                self.flags.insert(name)
            } else if options.contains(name) {
                if let inline {
                    self.options[name] = inline
                } else if let value = rest.first, !value.hasPrefix("--") {
                    self.options[name] = value
                    rest = rest.dropFirst()
                } else {
                    throw Refusal.missingValue(argument)
                }
            } else {
                throw Refusal.unknown("--\(name)")
            }
        }
    }

    /// Refuses any option or flag given that `form` does not take: one tool's forms share a parse,
    /// and an option meant for another form is a mistake to say, not one to ignore.
    public func only(_ allowed: Set<String>, for form: String) throws {
        let given = Set(options.keys).union(flags)
        if let stray = given.subtracting(allowed).sorted().first { throw Refusal.notTaken("--\(stray)", by: form) }
    }

    /// `--` alone ends the options; anything else starting with two dashes is one.
    static func isOption(_ argument: String) -> Bool {
        argument.hasPrefix("--") && argument.count > 2
    }
}

/// Dates as the tools read and write them: ISO 8601, in the phone's own time zone unless the text
/// names an offset. A date alone is a day (an all-day event, a reminder due that day).
public enum ToolDates {
    public struct Reading: Sendable, Equatable {
        public var date: Date
        /// False for a date with no time of day.
        public var hasTime: Bool

        public init(date: Date, hasTime: Bool) {
            self.date = date
            self.hasTime = hasTime
        }
    }

    public static func read(_ text: String, in zone: TimeZone = .current) -> Reading? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: text) { return Reading(date: date, hasTime: true) }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return Reading(date: date, hasTime: true) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        local.calendar = Calendar(identifier: .gregorian)
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return Reading(date: date, hasTime: true) }
        }
        local.dateFormat = "yyyy-MM-dd"
        if let date = local.date(from: text) { return Reading(date: date, hasTime: false) }
        return nil
    }

    /// A moment with the phone's offset: `2026-09-26T14:30:00-07:00`.
    public static func write(_ date: Date, in zone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A day: `2026-09-26`.
    public static func day(_ date: Date, in zone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// A span from now: `90s`, `15m`, `2h`, `1d`, or a bare number of seconds.
    public static func duration(_ text: String) -> TimeInterval? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last, let scale = units[unit], let amount = Double(text.dropLast()), amount > 0, amount.isFinite {
            return amount * scale
        }
        if let seconds = Double(text), seconds > 0, seconds.isFinite { return seconds }
        return nil
    }
}
