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
    /// Cancels one; throws what AlarmKit throws.
    func cancel(id: UUID) async throws
}

/// AlarmKit's refusal of one alarm more than it holds, said so the mind can ask which to drop.
struct AlarmLimit: Error {
    let reason = "the phone already holds as many of Topo's alarms as AlarmKit allows"
}

/// Below iOS 26: no AlarmKit, so no timer.
struct NoAlarms: AlarmScheduler {
    var authorizer: (any Authorizer)? { nil }
    func schedule(id: UUID, label: String, duration: TimeInterval) async throws {}
    func alarms() async throws -> [(id: UUID, state: String)] { [] }
    func cancel(id: UUID) async throws {}
}

/// The label and the time each alarm sounds, which AlarmKit's own `Alarm` does not carry, kept for
/// `topo timer list` while Topo runs (and soonest first by them); a relaunch lists an alarm by its id
/// and state alone, and those last.
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
    /// Where Topo stands, read at the moment a new prompt would go up (`OnScreen`): the system's
    /// prompt can be raised unless Topo is in the background. A system alert makes the app inactive
    /// and not backgrounded, so a start made under another app's alert still asks, its prompt
    /// following; one made under AlarmKit's own prompt waits on that one (`PermissionBroker`).
    var state: @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }
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
            // Judged as written, before its lines are joined and its ends trimmed, so a longer label
            // is refused rather than cut to fit.
            let given = parsed.words.count == 2 ? parsed.words[1] : "Timer"
            guard given.count <= Self.labelLimit else {
                throw ToolFailure("the label is \(given.count) characters, past \(Self.labelLimit)", status: ToolReply.usage)
            }
            let label = PhoneTool.flat(given).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { throw ToolFailure("the label is empty", status: ToolReply.usage) }
            return .start(span: seconds, label: label)
        default:
            throw Misuse("timer takes a span, list or cancel")
        }
    }

    func run(_ arguments: [String]) async -> ToolReply {
        let alarms = scheduler.authorizer
        let asking = alarms.map { OnScreen(alarms: $0, state: state) }
        // Only a start needs the permission; one below iOS 26 has none to ask and is answered in `start`.
        let reply = await PhoneTool.run({ (call: Call) -> (any Authorizer)? in
            if case .start = call { asking } else { nil }
        }, broker: broker, usage: usage, parse: { try parse(arguments) }) { call in
            switch call {
            case .list: await list()
            case let .cancel(id): await cancel(id)
            case let .start(span, label): await start(span: span, label: label)
            }
        }
        // A refusal over a permission still undetermined is a prompt nobody was shown: `OnScreen`
        // declined it, for this call or for the one whose prompt it joined. A refusal the person
        // made is a standing of denied, said as one.
        if reply.status == ToolReply.denied, let alarms, await alarms.access() == .undetermined { return Self.offScreen }
        return reply
    }

    /// AlarmKit's permission, asked only with Topo off the background: the system's prompt needs
    /// Topo in front. Where it is in the background as the prompt would go up, nothing is asked:
    /// the answer is yes if another call's prompt was granted since the broker read the standing,
    /// and otherwise no, which `run` says as `offScreen` because the standing is still undetermined.
    /// A call that finds a prompt already up waits on it and never reaches `request`.
    ///
    /// Read off the standing, the answer is wrong only at edges no person reaches or no suite can:
    /// a refusal made within microseconds of Topo leaving the front, an AlarmKit whose standing
    /// lags its prompt's answer (said once as `offScreen`, then as the refusal it is), and a
    /// request AlarmKit throws on (`AlarmAuthorizer`), which leaves the standing undetermined.
    struct OnScreen: Authorizer {
        let alarms: any Authorizer
        let state: @MainActor () -> UIApplication.State
        var name: String { alarms.name }
        func access() async -> Access { await alarms.access() }
        func request() async -> Bool {
            guard await state() != .background else { return await alarms.access() == .granted }
            return await alarms.request()
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
        } catch let error as AlarmLimit {
            return .failed("topo: no timer was set: \(error.reason). Cancel one with topo timer cancel, or ask the person which to drop.\n")
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
        let missing = ToolReply(status: ToolReply.failed, text: "topo: no timer of Topo's with the id \(id)\n")
        guard let uuid = UUID(uuidString: id) else { return missing }
        // Asked of the list first, so a cancel AlarmKit refused is not said as no such timer: that
        // one may still sound.
        do {
            guard try await scheduler.alarms().contains(where: { $0.id == uuid }) else { return missing }
            try await scheduler.cancel(id: uuid)
        } catch {
            return .failed("topo: AlarmKit did not cancel \(id), which may still sound: \(error.localizedDescription)\n")
        }
        await book().drop(uuid)
        return .ok("cancelled: \(id)\n")
    }
}
