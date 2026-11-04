import Foundation
import TopoTools
import UIKit

/// The system's alarms: AlarmKit on iOS 26 (`AlarmKitScheduler`), a fake in the suites, nothing
/// below iOS 26 (`NoAlarms`).
protocol AlarmScheduler: Sendable {
    /// The permission AlarmKit asks for, or nil where the phone has no AlarmKit.
    var authorizer: (any Authorizer)? { get }
    func schedule(id: UUID, label: String, duration: TimeInterval) async throws
    /// Topo's alarms and their states (AlarmKit lists only the app's own).
    func alarms() async throws -> [(id: UUID, state: String)]
    /// Whether there was one with that id to cancel.
    func cancel(id: UUID) async -> Bool
}

/// Below iOS 26: no AlarmKit, so no timer.
struct NoAlarms: AlarmScheduler {
    var authorizer: (any Authorizer)? { nil }
    func schedule(id: UUID, label: String, duration: TimeInterval) async throws {}
    func alarms() async throws -> [(id: UUID, state: String)] { [] }
    func cancel(id: UUID) async -> Bool { false }
}

/// The label and the time each alarm sounds, which AlarmKit's own `Alarm` does not carry, kept for
/// `topo timer list` while Topo runs; a relaunch lists an alarm by its id and state alone.
@MainActor
final class TimerBook {
    static let shared = TimerBook()

    /// AlarmKit where the phone has it.
    nonisolated static var scheduler: any AlarmScheduler {
        if #available(iOS 26, *) { AlarmKitScheduler() } else { NoAlarms() }
    }
    private var known: [UUID: (label: String, fires: Date)] = [:]

    func remember(_ id: UUID, label: String, fires: Date) { known[id] = (label, fires) }
    func entry(_ id: UUID) -> (label: String, fires: Date)? { known[id] }
    func drop(_ id: UUID) { known[id] = nil }
}

/// `topo timer`: a countdown that sounds at zero, as an AlarmKit alarm, which sounds behind the
/// lock and through silent mode. Where alarms are refused or the phone has no AlarmKit, nothing is
/// set and the reply says why, so the mind asks the person what they wanted rather than setting
/// something lesser. A timer outlives a sign-out: it ends by itself and is dismissed in a tap.
struct TimerTool: Tool {
    let scheduler: any AlarmScheduler
    let book: @MainActor () -> TimerBook
    let broker: PermissionBroker
    /// Whether Topo is on the screen, where the system's prompt can be raised.
    var onScreen: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUID() }

    static let labelLimit = 40
    static let longest: TimeInterval = 24 * 3600

    let name = "timer"
    let summary = "a timer that sounds at zero, behind the lock and through silent mode; list or cancel them"
    let usage = """
    topo timer SPAN [LABEL]          a timer of SPAN (90s, 15m, 2h; 1s to 24h) that sounds at zero; LABEL
                                     (at most 40 characters) is what the lock screen and the alert say
    topo timer list                  Topo's timers, id first
    topo timer cancel ID             cancel one before it sounds

    A timer is an alarm: it counts down on the lock screen and sounds at zero with the phone locked
    or on silent, until it is stopped. Topo asks once to allow alarms, with Topo on the screen.
    Where alarms are not allowed (status 5) or the phone's iOS is older than 26 (status 1), nothing
    is set: ask the person what the timer was for, rather than setting something else in its place.
    """

    enum Call: Equatable {
        case list
        case cancel(id: String)
        case start(span: TimeInterval, label: String)
    }

    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments, options: [])
        switch parsed.words.first {
        case "list" where parsed.words.count == 1:
            return .list
        case "cancel" where parsed.words.count == 2:
            return .cancel(id: parsed.words[1])
        case "list":
            throw Misuse("timer list takes nothing more")
        case "cancel":
            throw Misuse("timer cancel takes one id")
        case let span? where (1...2).contains(parsed.words.count):
            guard let seconds = ToolDates.duration(span) else {
                throw ToolFailure("\(span) is not a span; write it as 90s, 15m or 2h", status: ToolReply.usage)
            }
            guard seconds >= 1, seconds <= Self.longest else {
                throw ToolFailure("a timer runs from 1s to 24h; \(span) is outside that", status: ToolReply.usage)
            }
            let label = parsed.words.count == 2 ? PhoneTool.flat(parsed.words[1]) : "Timer"
            guard !label.isEmpty else { throw ToolFailure("the label is empty", status: ToolReply.usage) }
            guard label.count <= Self.labelLimit else {
                throw ToolFailure("the label is \(label.count) characters, past \(Self.labelLimit)", status: ToolReply.usage)
            }
            return .start(span: seconds, label: label)
        default:
            throw Misuse("timer takes a span, list or cancel")
        }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        let authorizer = scheduler.authorizer
        // The system's prompt needs Topo in front: a start that would raise it off the screen asks
        // nothing. The parse is pure, so reading it here and again in the run costs nothing.
        if case .start? = try? parse(arguments), let authorizer, await authorizer.access() == .undetermined, await !onScreen() {
            return Self.offScreen
        }
        // Only a start needs the permission; one below iOS 26 has none to ask and is answered in `start`.
        return await PhoneTool.run({ (call: Call) -> (any Authorizer)? in
            if case .start = call { authorizer } else { nil }
        }, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case .list: await list()
            case let .cancel(id): await cancel(id)
            case let .start(span, label): await start(span: span, label: label)
            }
        }
    }

    static let noAlarmKit = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: this phone's iOS has no AlarmKit (it needs iOS 26), so Topo cannot set an alarm here. Ask the person what the timer was for.\n")
    static let offScreen = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: Topo asks once to allow alarms, and can ask only while it is on the screen. Ask the person to open Topo, then set the timer again.\n")

    private func start(span: TimeInterval, label: String) async -> ToolReply {
        guard scheduler.authorizer != nil else { return Self.noAlarmKit }
        let id = makeID()
        let fires = now().addingTimeInterval(span)
        do {
            try await scheduler.schedule(id: id, label: label, duration: span)
        } catch {
            return .failed("topo: AlarmKit did not set the timer: \(error.localizedDescription)\n")
        }
        await book().remember(id, label: label, fires: fires)
        return .ok("set: " + PhoneTool.line([id.uuidString.lowercased(), label, "sounds at " + ToolDates.write(fires)]) + "\n")
    }

    private func list() async -> ToolReply {
        let book = await book()
        var lines: [(fires: Date?, line: String)] = []
        do {
            for alarm in try await scheduler.alarms() {
                let entry = await book.entry(alarm.id)
                lines.append((entry?.fires, PhoneTool.line([alarm.id.uuidString.lowercased(), entry?.label,
                                                            entry.map { "sounds at " + ToolDates.write($0.fires) }, alarm.state])))
            }
        } catch {
            return .failed("topo: AlarmKit did not list the timers: \(error.localizedDescription)\n")
        }
        let text = lines.sorted { ($0.fires ?? .distantFuture) < ($1.fires ?? .distantFuture) }.map(\.line)
        return .ok(PhoneTool.lines(text, none: "no timers"))
    }

    private func cancel(_ id: String) async -> ToolReply {
        guard let uuid = UUID(uuidString: id), await scheduler.cancel(id: uuid) else {
            return .failed("topo: no timer of Topo's with the id \(id)\n")
        }
        await book().drop(uuid)
        return .ok("cancelled: \(id)\n")
    }
}
