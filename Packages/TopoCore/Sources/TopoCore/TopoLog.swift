import Foundation
import OSLog
import os

/// The app's categories in the unified log, each with a level the mind can switch
/// (`topo log level`). One list, so the switch, the listing and every writer name the same ones.
public enum LogCategory: String, CaseIterable, Sendable {
    case activity, audio, auth, bridge, cloud, dns, models, perf, proxy, resident, tools
}

/// How much a category writes. `default` is what it writes unasked; `debug` adds its detail
/// lines, and only for a time; `off` writes its errors and nothing else.
public enum LogLevel: String, CaseIterable, Sendable {
    case debug, `default`, off
}

/// Each category's level, in this process's memory alone: a launch starts every category at
/// `default`, and a level other than `default` holds until its expiry, after which it reads as
/// `default` again. Detail is bounded so a switch nobody turns off costs nothing behind the lock.
public final class LogLevels: Sendable {
    public struct Setting: Equatable, Sendable {
        public var level: LogLevel
        /// When the level goes back to `default`; nil for `default`, and for an `off` given no time.
        public var until: Date?
    }

    /// How long `debug` lasts when no time is given, and the most it can be given.
    public static let debugDefault: TimeInterval = 30 * 60
    public static let longest: TimeInterval = 2 * 60 * 60

    public static let shared = LogLevels()

    private let now: @Sendable () -> Date
    private let settings = OSAllocatedUnfairLock<[LogCategory: Setting]>(initialState: [:])
    /// Told once of each level that ran out, at the first moment it was looked at after.
    private let expired: @Sendable (LogCategory, LogLevel) -> Void

    /// `expired` is told of a level that ran out; unless given, the category says so in its own line.
    public init(now: @escaping @Sendable () -> Date = { Date() }, expired: (@Sendable (LogCategory, LogLevel) -> Void)? = nil) {
        self.now = now
        self.expired = expired ?? { category, level in
            TopoLog.logger(category).notice("level \(level.rawValue, privacy: .public) ended at its expiry")
        }
    }

    /// The category's setting now; one past its expiry is put back to `default` here.
    public func setting(_ category: LogCategory) -> Setting {
        let at = now()
        let (current, ran) = settings.withLock { all -> (Setting, LogLevel?) in
            guard let kept = all[category] else { return (Setting(level: .default), nil) }
            if let until = kept.until, until <= at {
                all[category] = nil
                return (Setting(level: .default), kept.level)
            }
            return (kept, nil)
        }
        if let ran { expired(category, ran) }
        return current
    }

    public func level(_ category: LogCategory) -> LogLevel { setting(category).level }

    /// Sets a level for `duration` seconds. `debug` takes `debugDefault` when given none, and no
    /// level is held past `longest`; `default` takes no time, being where every level ends.
    @discardableResult
    public func set(_ category: LogCategory, _ level: LogLevel, for duration: TimeInterval? = nil) -> Setting {
        let span: TimeInterval? = switch level {
        case .default: nil
        case .debug: min(duration ?? Self.debugDefault, Self.longest)
        case .off: duration.map { min($0, Self.longest) }
        }
        let setting = Setting(level: level, until: span.map { now().addingTimeInterval($0) })
        settings.withLock { $0[category] = level == .default ? nil : setting }
        return setting
    }
}

/// A category's writer: the one way the app's code reaches the unified log, so the category's
/// level is read at every line. Every value is written public: a line carries record ids, error
/// codes, timings and states, never what was said, a secret or a token, at any level.
public struct TopoLog: Sendable {
    public static let subsystem = "zone.hexagon.topo"

    public let category: LogCategory
    private let levels: LogLevels
    private let logger: Logger

    public init(_ category: LogCategory, levels: LogLevels = .shared) {
        self.category = category
        self.levels = levels
        self.logger = Self.logger(category)
    }

    static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// True while the category is at `debug`: a detail line costs nothing to skip, but one that
    /// costs something to make asks first.
    public var detailed: Bool { levels.level(category) == .debug }

    /// A line written only while the category is at `debug`. At `notice`, which the phone keeps,
    /// so a line written between two reads is still there at the second.
    public func detail(_ line: @autoclosure () -> String) {
        guard detailed else { return }
        let line = line()
        logger.notice("\(line, privacy: .public)")
    }

    /// The category's ordinary lines, which `off` silences.
    public func info(_ line: @autoclosure () -> String) {
        guard levels.level(category) != .off else { return }
        let line = line()
        logger.info("\(line, privacy: .public)")
    }

    public func notice(_ line: @autoclosure () -> String) {
        guard levels.level(category) != .off else { return }
        let line = line()
        logger.notice("\(line, privacy: .public)")
    }

    /// Written at every level, `off` included.
    public func error(_ line: @autoclosure () -> String) {
        let line = line()
        logger.error("\(line, privacy: .public)")
    }
}
