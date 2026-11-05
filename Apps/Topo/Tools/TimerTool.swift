import Foundation
import os
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

/// A permission whose prompt says why it failed, where the system's request throws: AlarmKit's.
protocol ThrowingPrompt: Authorizer {
    /// Raises the prompt; true when granted. Throws what the system's request throws.
    func prompt() async throws -> Bool
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
    /// Where Topo stands, read as a call begins (to tell `leftBeforeThePrompt` from `offScreen`) and
    /// at the moment a new prompt would go up (`OnScreen`): the system's prompt can be raised unless
    /// Topo is in the background. A system alert over Topo leaves it inactive and not backgrounded,
    /// so a start made under one still asks; one made under AlarmKit's own prompt joins that one
    /// in `PermissionBroker`.
    var state: @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUID() }
    /// What the last prompt `OnScreen` was asked for came to, kept for every call that waited on it.
    let asked = Asked()

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
        let asking = alarms.map { OnScreen(alarms: $0, state: state, asked: asked) }
        let inFront = await state() != .background
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
        // A refusal the person made is a standing of denied, said as one. A no over a standing
        // still undetermined is no answer from the person, and is said as what the prompt this
        // call made or joined came to (`OnScreen`): declined in the background, the request
        // failing, or closing with nothing kept.
        if reply.status == ToolReply.denied, let alarms, await alarms.access() == .undetermined {
            switch asked.last {
            case .declined: return inFront ? Self.leftBeforeThePrompt : Self.offScreen
            case let .failed(reason): return Self.promptFailed(reason)
            case .answered, nil: return Self.promptUnanswered
            }
        }
        return reply
    }

    /// What a prompt came to.
    enum Outcome: Sendable, Equatable {
        /// Not raised: Topo was in the background.
        case declined
        /// Raised, and AlarmKit's request threw this.
        case failed(String)
        /// Raised and answered.
        case answered
    }

    /// The last prompt's outcome, written before its answer reaches the broker, so a call that
    /// joined that prompt reads it after.
    final class Asked: Sendable {
        private let value = OSAllocatedUnfairLock<Outcome?>(initialState: nil)
        var last: Outcome? { value.withLock { $0 } }
        func record(_ outcome: Outcome) { value.withLock { $0 = outcome } }
    }

    /// AlarmKit's permission, asked only with Topo off the background: the system's prompt needs
    /// Topo in front. Where it is in the background as the prompt would go up, nothing is asked:
    /// the answer is yes if another call's prompt was granted since the broker read the standing,
    /// and otherwise no, which `run` says as `offScreen`, or as `leftBeforeThePrompt` for a call
    /// begun with Topo out of the background, because the standing is still undetermined. A call
    /// that finds a prompt already up waits on it and never reaches `request`.
    ///
    /// Each prompt records what it came to (`Asked`), so `run` says the cause: a request AlarmKit
    /// threw on by its error, and one that answered no while leaving the standing undetermined
    /// (an AlarmKit whose standing lags its answer) as a prompt that kept no answer.
    struct OnScreen: Authorizer {
        let alarms: any Authorizer
        let state: @MainActor () -> UIApplication.State
        let asked: Asked
        var name: String { alarms.name }
        func access() async -> Access { await alarms.access() }
        func request() async -> Bool {
            guard await state() != .background else {
                if await alarms.access() == .granted { return true }
                asked.record(.declined)
                return false
            }
            guard let throwing = alarms as? any ThrowingPrompt else {
                let granted = await alarms.request()
                asked.record(.answered)
                return granted
            }
            do {
                let granted = try await throwing.prompt()
                asked.record(.answered)
                return granted
            } catch {
                asked.record(.failed(error.localizedDescription))
                return false
            }
        }
    }

    static let noAlarmKit = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: this phone's iOS has no AlarmKit (it needs iOS 26), so Topo cannot set an alarm here. Ask the person what the timer was for.\n")
    static let offScreen = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: Topo asks once to allow alarms, and can ask only while it is on the screen. Ask the person to open Topo, then set the timer again.\n")

    static let leftBeforeThePrompt = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: it was asked for with Topo in front, but Topo went to the background before it could put up the prompt to allow alarms. Tell the person that, and ask them to set it again a moment slower, with Topo on the screen; once the prompt is answered it is not asked again.\n")

    static func promptFailed(_ reason: String) -> ToolReply {
        ToolReply(status: ToolReply.failed, text:
            "topo: no timer was set: AlarmKit's request to allow alarms failed (\(PhoneTool.flat(reason))); nothing was refused, and the person was likely not asked. Tell the person, and ask them to set it again with Topo on the screen.\n")
    }
    static let promptUnanswered = ToolReply(status: ToolReply.failed, text:
        "topo: no timer was set: the prompt to allow alarms closed and AlarmKit kept no answer, so alarms are neither allowed nor refused. Ask the person to set it again with Topo on the screen, and to answer the prompt.\n")

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
