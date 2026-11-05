import Foundation
import os
import TopoTools
import UIKit

/// A timer or an alarm as the mind composed it: when it sounds, what it says in each state, and
/// which buttons it carries. `AlarmKitScheduler` makes it AlarmKit's; the suites read it as it is.
struct TimerPlan: Equatable, Sendable {
    enum When: Equatable, Sendable {
        /// A countdown of this many seconds, starting now.
        case after(TimeInterval)
        /// Once, at this moment.
        case on(Date)
        /// At this hour and minute in the phone's time zone: the next one when `days` is empty,
        /// otherwise every one of those days.
        case at(hour: Int, minute: Int, days: [Locale.Weekday])
    }

    struct Button: Equatable, Sendable {
        var text: String
        var icon: String
    }

    var when: When
    /// What the countdown says, and the alert unless `title` says otherwise.
    var label: String
    /// What the alert says.
    var title: String
    /// Pause on the countdown, Resume while paused; both or neither.
    var pause: Button?
    var resume: Button?
    var pausedTitle: String
    /// Cancel beside the countdown and the paused time: the widget's own button.
    var cancel: Button?
    /// The alert's second button, and what it does: `again` starts a countdown of that span
    /// (AlarmKit's `.countdown`, its `postAlert`), `tells` hands Topo the words kept for it.
    var second: Button?
    var again: TimeInterval?
    var tells = false
    /// The system's Stop hands Topo the words kept for it.
    var tellsOnStop = false
    var buttonColor: WidgetColour
    var tint: WidgetColour
    /// A file in the app's `Library/Sounds` that the alert plays; the system's when nil.
    var sound: String?

    /// Whether the alarm ever counts down, which is when Pause and Cancel have a countdown to sit on.
    var countsDown: Bool {
        if case .after = when { return true }
        return again != nil
    }
}

/// One of Topo's alarms as AlarmKit reports it, with what its Live Activity says of the countdown.
struct TimerStatus: Equatable, Sendable {
    enum State: String, Sendable {
        /// Waiting for the moment it is set for.
        case set
        case counting, paused, sounding, unknown
    }

    var id: UUID
    var state: State
    /// When it is set for, where AlarmKit says: absent for a timer's first countdown.
    var when: TimerPlan.When?
    /// When a countdown reaches zero, from its Live Activity.
    var fires: Date?
    /// What is left of a paused countdown, from its Live Activity.
    var left: TimeInterval?
}

/// The system's alarms: AlarmKit on iOS 26 (`AlarmKitScheduler`), a fake in the suites, nothing
/// below iOS 26 (`NoAlarms`).
protocol AlarmScheduler: Sendable {
    /// The permission AlarmKit asks for, or nil where the phone has no AlarmKit.
    var authorizer: (any Authorizer)? { get }
    func schedule(id: UUID, plan: TimerPlan) async throws
    /// Topo's alarms (AlarmKit lists only the app's own).
    func alarms() async throws -> [TimerStatus]
    /// Each throws what AlarmKit throws.
    func pause(id: UUID) async throws
    func resume(id: UUID) async throws
    /// AlarmKit's `countdown(id:)`: a sounding alarm's next countdown.
    func again(id: UUID) async throws
    func stop(id: UUID) async throws
    func cancel(id: UUID) async throws
}

/// A permission whose prompt says why it failed, where the system's request throws: AlarmKit's.
protocol ThrowingPrompt: Authorizer {
    /// Raises the prompt and answers the standing the system's request returned, which can be
    /// ahead of what `access()` reads. Throws what the request throws.
    func prompt() async throws -> Access
}

/// AlarmKit's refusal of one alarm more than it holds, said so the mind can ask which to drop.
struct AlarmLimit: Error {
    let reason = "the phone already holds as many of Topo's alarms as AlarmKit allows"
}

/// Below iOS 26: no AlarmKit, so no timer.
struct NoAlarms: AlarmScheduler {
    var authorizer: (any Authorizer)? { nil }
    func schedule(id: UUID, plan: TimerPlan) async throws {}
    func alarms() async throws -> [TimerStatus] { [] }
    func pause(id: UUID) async throws {}
    func resume(id: UUID) async throws {}
    func again(id: UUID) async throws {}
    func stop(id: UUID) async throws {}
    func cancel(id: UUID) async throws {}
}

/// What each alarm was set as, which AlarmKit's `Alarm` does not carry, kept on disk by its id so
/// a relaunch still knows it: the label and the plan's shape for `list`, and the words a button
/// hands Topo with the login it was set under (`TimerPresses`). A record is written after AlarmKit
/// takes the alarm and dropped once AlarmKit no longer lists it.
final class TimerRecords: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var label: String
        /// When it was written: a sweep spares a record written after the list it judges by.
        var made: Date
        /// The first countdown's end, for a timer.
        var fires: Date?
        /// The span of a timer's countdown.
        var span: TimeInterval?
        var again: TimeInterval?
        /// The words the second button and Stop hand Topo, and the button's own.
        var tell: String?
        var onStop: String?
        var second: String?
        /// The login the words were kept under: a press under any other sends nothing.
        var login: String?
        /// The file in `Library/Sounds` the alert plays.
        var sound: String?
    }

    static let shared = TimerRecords(folder: URL.applicationSupportDirectory.appendingPathComponent("Timers", isDirectory: true))

    /// AlarmKit where the phone has it.
    static var scheduler: any AlarmScheduler {
        if #available(iOS 26, *) { AlarmKitScheduler() } else { NoAlarms() }
    }

    let folder: URL
    private let lock = OSAllocatedUnfairLock()

    init(folder: URL) { self.folder = folder }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    /// Kept readable while the phone is locked after its first unlock, since a button pressed on
    /// the lock screen is read here.
    func write(_ record: Record, for id: UUID) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func read(_ id: UUID) -> Record? {
        lock.withLock { (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } }
    }

    func drop(_ id: UUID) {
        lock.withLock { try? FileManager.default.removeItem(at: file(id)) }
    }

    /// Every record AlarmKit no longer lists, written before `listed` was read, and answers the
    /// sound files they named, for the caller to remove.
    @discardableResult
    func sweep(keeping alarms: Set<UUID>, readAt listed: Date) -> [String] {
        lock.withLock {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var sounds: [String] = []
            for name in names where name.hasSuffix(".json") {
                guard let id = UUID(uuidString: String(name.dropLast(5))), !alarms.contains(id) else { continue }
                let url = folder.appendingPathComponent(name)
                let record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
                if let record, record.made >= listed { continue }
                if let sound = record?.sound { sounds.append(sound) }
                try? FileManager.default.removeItem(at: url)
            }
            return sounds
        }
    }
}

/// `topo timer`: a countdown or an alarm, as AlarmKit makes them, which sound behind the lock and
/// through silent mode, with every control AlarmKit offers for the mind to compose: Pause and
/// Resume on the countdown, a second button at the alert that starts the next countdown or hands
/// Topo a turn, a turn at Stop, Cancel on the countdown, its words, symbols and colours, a sound,
/// and an alarm at a moment or on chosen days. Where alarms are refused or the phone has no
/// AlarmKit, nothing is set and the reply says why, so the mind asks the person what they wanted
/// rather than setting something lesser. An alarm outlives a sign-out; the turns its buttons hand
/// Topo do not.
struct TimerTool: Tool {
    let scheduler: any AlarmScheduler
    let records: TimerRecords
    let broker: PermissionBroker
    /// Where Topo stands, read as a call begins (to tell `leftBeforeThePrompt` from `offScreen`) and
    /// at the moment a new prompt would go up (`OnScreen`): the system's prompt can be raised unless
    /// Topo is in the background. A system alert over Topo leaves it inactive and not backgrounded,
    /// so a start made under one still asks; one made under AlarmKit's own prompt joins that one
    /// in `PermissionBroker`.
    var state: @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState }
    var now: @Sendable () -> Date = { Date() }
    var makeID: @Sendable () -> UUID = { UUID() }
    var zone: TimeZone = .current
    /// The login a button's words are kept under, nil while signed out (`ShareStore`'s door).
    var login: @Sendable () -> String? = { ShareStore.shared()?.door()?.login }
    /// Whether the system has a symbol by this name.
    var hasSymbol: @Sendable (String) -> Bool = { UIImage(systemName: $0) != nil }
    /// Copies a sound file from the guest's home into `Library/Sounds` under the name given.
    var sounds: TimerSounds = TimerSounds()
    /// What the last prompt `OnScreen` was asked for came to, kept for every call that waited on it.
    let asked = Asked()

    static let labelLimit = 40
    static let buttonLimit = 20
    static let wordsLimit = 500
    static let longest: TimeInterval = 24 * 3600

    let name = "timer"
    let summary = "timers and alarms that sound behind the lock and on silent, with pause, again, buttons that tell Topo, days and sounds"
    let usage = """
    topo timer SPAN [LABEL] [OPTIONS]      a countdown of SPAN (90s, 15m, 2h; 1s to 24h) that sounds at zero
    topo timer at TIME [LABEL] [OPTIONS]   an alarm at TIME: HH:MM (24-hour, the next one; with --every, those days)
                                           or a moment, 2026-11-05T07:30
    topo timer list                        Topo's timers and alarms, id first, with their state
    topo timer pause ID | resume ID        hold a counting timer, or set a held one counting again
    topo timer again ID                    one sounding: start its next countdown (the --again span)
    topo timer stop ID                     one sounding: stop it (one with --every waits for its next day)
    topo timer cancel ID                   take it off, whatever its state

    LABEL (at most 40 characters, "Timer" if none) is what the countdown and the alert say.
    The alert:
      --title TEXT          what the alert says instead of LABEL
      --again SPAN|same     a second button that starts another countdown of SPAN; same is the timer's own
                            (an alarm's snooze: give a span)
      --tell WORDS          a second button that hands Topo WORDS as a turn (with --again, it does both)
      --button-text TEXT    the second button's words (Again, Snooze or Tell Topo); --button-icon SYMBOL
      --on-stop WORDS       the system's Stop also hands Topo WORDS as a turn
      --sound FILE          a .caf, .aiff or .wav under /home/topo, under 30 seconds, played instead of the
                            system's sound
    The countdown (a timer, or an alarm with --again), on the lock screen and in the Dynamic Island:
      --pause               Pause, and Resume while paused; --pause-text, --pause-icon, --resume-text,
                            --resume-icon, --paused-title TEXT (what it says while paused)
      --cancel              a Cancel button; --cancel-text, --cancel-icon
    Every alarm:
      --every DAYS          with at HH:MM: daily, weekdays, weekends, or days as mon,wed,fri
      --tint COLOR          the alarm's colour; --button-color COLOR the buttons' words. A colour is primary,
                            secondary, highlight, signal, onPrimary, text, …, or #RRGGBB, or #LIGHT/#DARK
    Button words are at most 20 characters, WORDS at most 500, a SYMBOL an SF Symbol name.

    An alarm sounds with the phone locked or on silent, until it is stopped. The person can press
    every button on the lock screen without unlocking, so a --tell turn arrives from a locked phone:
    WORDS are your own, read back to you, saying what the press means. A turn is sent only while the
    login the alarm was set under is signed in. Topo asks once to allow alarms, with Topo on the
    screen. Where alarms are not allowed (status 5) or the phone's iOS is older than 26 (status 1),
    nothing is set: ask the person what it was for, rather than setting something else in its place.
    """

    enum Call: Equatable {
        case list
        case act(Act, id: String)
        case start(TimerPlan, tell: String?, onStop: String?, soundPath: String?)
    }

    enum Act: String, Equatable {
        case pause, resume, again, stop, cancel
    }

    static let alertOptions: Set<String> = ["title", "again", "tell", "button-text", "button-icon", "on-stop", "sound",
                                            "pause-text", "pause-icon", "resume-text", "resume-icon", "paused-title",
                                            "cancel-text", "cancel-icon", "every", "tint", "button-color"]
    static let alertFlags: Set<String> = ["pause", "cancel"]

    func parse(_ arguments: [String]) throws -> Call {
        let parsed = try Arguments(arguments, options: Self.alertOptions, flags: Self.alertFlags)
        let words = parsed.words
        switch words.first {
        case "list":
            try parsed.only([], for: "timer list")
            guard words.count == 1 else { throw Misuse("timer list takes nothing more") }
            return .list
        case let verb? where Act(rawValue: verb) != nil:
            try parsed.only([], for: "timer \(verb)")
            guard words.count == 2 else { throw Misuse("timer \(verb) takes one id") }
            return .act(Act(rawValue: verb)!, id: words[1])
        case "at":
            guard (2...3).contains(words.count) else { throw Misuse("timer at takes a time and at most a label") }
            let when = try at(words[1], every: parsed.options["every"])
            return try start(when, label: words.count == 3 ? words[2] : nil, parsed)
        case let span? where (1...2).contains(words.count):
            guard let seconds = ToolDates.duration(span) else {
                throw ToolFailure("\(span) is not a span; write it as 90s, 15m or 2h", status: ToolReply.usage)
            }
            guard seconds >= 1, seconds <= Self.longest else {
                throw ToolFailure("a timer runs from 1s to 24h; \(span) is outside that", status: ToolReply.usage)
            }
            if parsed.options["every"] != nil { throw usage("--every repeats an alarm: write timer at HH:MM --every DAYS") }
            return try start(.after(seconds), label: words.count == 2 ? words[1] : nil, parsed)
        default:
            throw Misuse("timer takes a span, at, list, pause, resume, again, stop or cancel")
        }
    }

    private func usage(_ text: String) -> ToolFailure { ToolFailure(text, status: ToolReply.usage) }

    /// `at`'s time: HH:MM, with or without `--every`, or a moment ahead with no `--every`.
    private func at(_ text: String, every: String?) throws -> TimerPlan.When {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
           !text.contains("-"), let hour = Int(parts[0]), let minute = Int(parts[1]), parts[1].count == 2 {
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw usage("\(text) is not a time of day; write it as HH:MM, 00:00 to 23:59")
            }
            return .at(hour: hour, minute: minute, days: try every.map(Self.days) ?? [])
        }
        guard let reading = ToolDates.read(text, in: zone), reading.hasTime else {
            throw usage("\(text) is not a time; write it as 07:30 or 2026-11-05T07:30")
        }
        if every != nil { throw usage("--every repeats a time of day: write at HH:MM --every DAYS, not a date") }
        guard reading.date > now() else { throw usage("\(text) has passed") }
        return .on(reading.date)
    }

    static let weekdays: [(name: String, day: Locale.Weekday)] = [
        ("mon", .monday), ("tue", .tuesday), ("wed", .wednesday), ("thu", .thursday), ("fri", .friday), ("sat", .saturday), ("sun", .sunday),
    ]

    static func days(_ text: String) throws -> [Locale.Weekday] {
        switch text.lowercased() {
        case "daily": return weekdays.map(\.day)
        case "weekdays": return Array(weekdays.prefix(5).map(\.day))
        case "weekends": return Array(weekdays.suffix(2).map(\.day))
        default: break
        }
        var days: [Locale.Weekday] = []
        for name in text.lowercased().split(separator: ",", omittingEmptySubsequences: false) {
            guard let day = weekdays.first(where: { $0.name == name })?.day else {
                throw ToolFailure("--every \(text): \(name.isEmpty ? "an empty day" : String(name)) is not a day; write daily, weekdays, weekends or mon,wed,fri",
                                  status: ToolReply.usage)
            }
            if !days.contains(day) { days.append(day) }
        }
        return days
    }

    /// A start's plan from its options, each judged as written: past its limit is refused, never cut.
    private func start(_ when: TimerPlan.When, label given: String?, _ parsed: Arguments) throws -> Call {
        let label = try text(given ?? "Timer", "the label", limit: Self.labelLimit)
        let options = parsed.options
        func option(_ name: String, limit: Int) throws -> String? {
            try options[name].map { try text($0, "--\(name)", limit: limit) }
        }
        func button(_ name: String, text fallback: String, icon fallbackIcon: String) throws -> TimerPlan.Button {
            let words = try option("\(name)-text", limit: Self.buttonLimit) ?? fallback
            let icon = options["\(name)-icon"] ?? fallbackIcon
            guard hasSymbol(icon) else { throw usage("--\(name)-icon \(icon) is not a symbol this phone has") }
            return TimerPlan.Button(text: words, icon: icon)
        }
        func colour(_ name: String, _ fallback: WidgetColour) throws -> WidgetColour {
            guard let text = options[name] else { return fallback }
            guard let colour = WidgetColour(option: text) else {
                throw usage("--\(name) \(text) is not a colour: a Theme token (primary, text, …), #RRGGBB, or #LIGHT/#DARK")
            }
            return colour
        }

        var again: TimeInterval?
        if let text = options["again"] {
            if text == "same" {
                guard case let .after(span) = when else { throw usage("--again same is a timer's own span; an alarm has none, so give one") }
                again = span
            } else {
                guard let span = ToolDates.duration(text), span >= 1, span <= Self.longest else {
                    throw usage("--again \(text) is not a span from 1s to 24h, or same")
                }
                again = span
            }
        }
        let tell = try option("tell", limit: Self.wordsLimit)
        let onStop = try option("on-stop", limit: Self.wordsLimit)

        var plan = TimerPlan(when: when, label: label, title: try option("title", limit: Self.labelLimit) ?? label,
                             pausedTitle: try option("paused-title", limit: Self.labelLimit) ?? label,
                             again: again, tells: tell != nil, tellsOnStop: onStop != nil,
                             buttonColor: try colour("button-color", .token(.onPrimary)),
                             tint: try colour("tint", .token(.primary)))
        if again != nil || tell != nil {
            let snooze = again != nil && { if case .after = when { false } else { true } }()
            plan.second = try button("button", text: again == nil ? "Tell Topo" : snooze ? "Snooze" : "Again",
                                     icon: again == nil ? "bubble.left" : snooze ? "zzz" : "repeat")
        } else if options["button-text"] != nil || options["button-icon"] != nil {
            throw usage("--button-text and --button-icon dress the second button, which --again or --tell makes")
        }

        let pausing = parsed.flags.contains("pause") || ["pause-text", "pause-icon", "resume-text", "resume-icon", "paused-title"].contains { options[$0] != nil }
        let cancelling = parsed.flags.contains("cancel") || options["cancel-text"] != nil || options["cancel-icon"] != nil
        if (pausing || cancelling), !plan.countsDown {
            throw usage("\(pausing ? "--pause" : "--cancel") sits on a countdown, and an alarm counts down only with --again")
        }
        if pausing {
            plan.pause = try button("pause", text: "Pause", icon: "pause.fill")
            plan.resume = try button("resume", text: "Resume", icon: "play.fill")
        }
        if cancelling { plan.cancel = try button("cancel", text: "Cancel", icon: "xmark") }

        let soundPath = options["sound"]
        if let soundPath { try TimerSounds.judgePath(soundPath) }
        return .start(plan, tell: tell, onStop: onStop, soundPath: soundPath)
    }

    /// Text judged as written, before its lines are joined and its ends trimmed, so a longer one is
    /// refused rather than cut to fit.
    private func text(_ given: String, _ what: String, limit: Int) throws -> String {
        guard given.count <= limit else {
            throw ToolFailure("\(what) is \(given.count) characters, past \(limit)", status: ToolReply.usage)
        }
        let flat = PhoneTool.flat(given).trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { throw ToolFailure("\(what) is empty", status: ToolReply.usage) }
        return flat
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
            case let .act(act, id): await self.act(act, id)
            case let .start(plan, tell, onStop, soundPath): await start(plan, tell: tell, onStop: onStop, soundPath: soundPath)
            }
        }
        // A refusal the person made is a standing of denied, said as one. A no over a standing
        // still undetermined is said as what the request of the prompt this call made or joined
        // returned (`OnScreen`): a refusal as one, however the standing lags; otherwise declined
        // in the background, the request failing, or closing with nothing kept.
        // The outcome is taken before the standing is read again, so a prompt begun meanwhile
        // cannot write over it.
        let outcome = asked.last
        if reply.status == ToolReply.denied, let alarms, await alarms.access() == .undetermined {
            switch outcome {
            case .declined: return inFront ? Self.leftBeforeThePrompt : Self.offScreen
            case let .failed(reason): return Self.promptFailed(reason)
            case .unanswered, nil: return Self.promptUnanswered
            case .granted, .refused: return reply
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
        /// Raised, and the request returned granted.
        case granted
        /// Raised, and the request returned a refusal: the person's no, said as one (status 5).
        case refused
        /// Raised, and the request returned the standing still undetermined.
        case unanswered
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
    /// Each prompt records what it came to (`Asked`), from what AlarmKit's request returned rather
    /// than what its standing reads after, so `run` says the cause: a request AlarmKit threw on by
    /// its error, a refusal as the refusal it is however the standing lags, and a request that
    /// returned the standing undetermined as a prompt that kept no answer.
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
                asked.record(granted ? .granted : .refused)
                return granted
            }
            do {
                switch try await throwing.prompt() {
                case .granted:
                    asked.record(.granted)
                    return true
                case .denied, .restricted:
                    asked.record(.refused)
                    return false
                case .undetermined:
                    asked.record(.unanswered)
                    return false
                }
            } catch {
                asked.record(.failed(error.localizedDescription))
                return false
            }
        }
    }

    static let noAlarmKit = ToolReply(status: ToolReply.failed, text:
        "topo: nothing was set: this phone's iOS has no AlarmKit (it needs iOS 26), so Topo cannot set an alarm here. Ask the person what it was for.\n")
    static let offScreen = ToolReply(status: ToolReply.failed, text:
        "topo: nothing was set: Topo asks once to allow alarms, and can ask only while it is on the screen. Ask the person to open Topo, then set it again.\n")

    static let leftBeforeThePrompt = ToolReply(status: ToolReply.failed, text:
        "topo: nothing was set: it was asked for with Topo in front, but Topo went to the background before it could put up the prompt to allow alarms. Tell the person that, and ask them to set it again a moment slower, with Topo on the screen; once the prompt is answered it is not asked again.\n")

    static func promptFailed(_ reason: String) -> ToolReply {
        ToolReply(status: ToolReply.failed, text:
            "topo: nothing was set: AlarmKit's request to allow alarms failed (\(PhoneTool.flat(reason))); nothing was refused, and the person was likely not asked. Tell the person, and ask them to set it again with Topo on the screen.\n")
    }
    static let promptUnanswered = ToolReply(status: ToolReply.failed, text:
        "topo: nothing was set: the prompt to allow alarms closed and AlarmKit kept no answer, so alarms are neither allowed nor refused. Ask the person to set it again with Topo on the screen, and to answer the prompt.\n")

    private func start(_ plan: TimerPlan, tell: String?, onStop: String?, soundPath: String?) async -> ToolReply {
        guard scheduler.authorizer != nil else { return Self.noAlarmKit }
        var plan = plan
        // A turn is kept under the login the alarm was set under, so one set while signed out
        // would carry words no press could ever send.
        let login = login()
        if tell != nil || onStop != nil, login == nil {
            return .failed("topo: nothing was set: --tell and --on-stop hand Topo a turn, and the phone is signed out\n")
        }
        let id = makeID()
        let set = now()
        if let soundPath {
            do {
                plan.sound = try await sounds.copy(soundPath, for: id)
            } catch let failure as ToolFailure {
                return ToolReply(status: failure.status, text: "topo: nothing was set: \(failure.text)\n")
            } catch {
                return .failed("topo: nothing was set: the sound could not be copied: \(error.localizedDescription)\n")
            }
        }
        do {
            try await scheduler.schedule(id: id, plan: plan)
        } catch {
            if let sound = plan.sound { sounds.remove(sound) }
            if error is AlarmLimit {
                return .failed("topo: nothing was set: \(AlarmLimit().reason). Cancel one with topo timer cancel, or ask the person which to drop.\n")
            }
            return .failed("topo: AlarmKit did not set it: \(error.localizedDescription)\n")
        }
        var fires: Date?
        var span: TimeInterval?
        if case let .after(seconds) = plan.when {
            span = seconds
            fires = set.addingTimeInterval(seconds)
        }
        let record = TimerRecords.Record(label: plan.label, made: set, fires: fires, span: span, again: plan.again, tell: tell,
                                         onStop: onStop, second: plan.second?.text, login: login, sound: plan.sound)
        var kept = ""
        do {
            try records.write(record, for: id)
        } catch {
            // The alarm stands; only what list says of it and the words a button hands are lost.
            kept = tell != nil || onStop != nil
                ? " (its record could not be kept, so its buttons will send no turn: \(error.localizedDescription))"
                : " (its record could not be kept, so list will not name it)"
        }
        let when = fires.map { "sounds at " + ToolDates.write($0, in: zone) } ?? describe(plan.when)
        return .ok("set: " + PhoneTool.line([id.uuidString.lowercased(), plan.label, when]) + kept + "\n")
    }

    /// When an alarm is set for, as `list` and a start say it.
    func describe(_ when: TimerPlan.When) -> String {
        switch when {
        case let .after(span): return "a \(Self.span(span)) timer"
        case let .on(date): return "sounds at " + ToolDates.write(date, in: zone)
        case let .at(hour, minute, days):
            let time = String(format: "%02d:%02d", hour, minute)
            guard !days.isEmpty else { return "sounds at " + ToolDates.write(next(hour: hour, minute: minute, days: []), in: zone) }
            let named = days.count == 7 ? "daily" : Self.weekdays.filter { days.contains($0.day) }.map(\.name).joined(separator: ",")
            return "at \(time) every \(named), next " + ToolDates.write(next(hour: hour, minute: minute, days: days), in: zone)
        }
    }

    /// The next moment at that hour and minute, on one of `days` when there are any.
    func next(hour: Int, minute: Int, days: [Locale.Weekday]) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let numbers = days.compactMap { day in Self.weekdays.firstIndex { $0.day == day }.map { ($0 + 1) % 7 + 1 } }
        let candidates = numbers.isEmpty
            ? [calendar.nextDate(after: now(), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)]
            : numbers.map { calendar.nextDate(after: now(), matching: DateComponents(hour: hour, minute: minute, weekday: $0), matchingPolicy: .nextTime) }
        return candidates.compactMap { $0 }.min() ?? now()
    }

    static func span(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole % 3600 == 0 { return "\(whole / 3600)h" }
        if whole % 60 == 0 { return "\(whole / 60)m" }
        if whole >= 60 { return "\(whole / 60)m\(whole % 60)s" }
        return "\(whole)s"
    }

    private func list() async -> ToolReply {
        let read = now()
        let alarms: [TimerStatus]
        do {
            alarms = try await scheduler.alarms()
        } catch {
            return .failed("topo: AlarmKit did not list them: \(error.localizedDescription)\n")
        }
        sweep(keeping: alarms, readAt: read)
        var lines: [(order: Date, line: String)] = []
        for alarm in alarms {
            let record = records.read(alarm.id)
            // A timer's countdown carries no schedule; its span is the record's.
            var shape = alarm.when.map(describe)
            if shape == nil, let span = record?.span { shape = "a \(Self.span(span)) timer" }
            var state = alarm.state.rawValue
            var order = Date.distantFuture
            if let fires = alarm.fires {
                state += ", sounds at " + ToolDates.write(fires, in: zone)
                order = fires
            } else if let left = alarm.left {
                state += ", \(Self.span(left)) left"
            } else if alarm.state == .counting, let fires = record?.fires {
                state += ", sounds at " + ToolDates.write(fires, in: zone)
                order = fires
            }
            if case let .on(date) = alarm.when { order = min(order, date) }
            if case let .at(hour, minute, days) = alarm.when { order = min(order, next(hour: hour, minute: minute, days: days)) }
            var extras: [String] = []
            if let again = record?.again { extras.append("again \(Self.span(again))") }
            if record?.tell != nil { extras.append("tells Topo at \(record?.second ?? "its button")") }
            if record?.onStop != nil { extras.append("tells Topo at Stop") }
            lines.append((order, PhoneTool.line([alarm.id.uuidString.lowercased(), record?.label, shape, state] + extras)))
        }
        let text = lines.sorted { $0.order < $1.order }.map(\.line)
        return .ok(PhoneTool.lines(text, none: "no timers"))
    }

    /// Drops the records and sounds of alarms AlarmKit no longer lists.
    private func sweep(keeping alarms: [TimerStatus], readAt read: Date) {
        for sound in records.sweep(keeping: Set(alarms.map(\.id)), readAt: read) { sounds.remove(sound) }
    }

    /// What each act needs the alarm to be doing, which AlarmKit itself may answer with nothing.
    private static func needs(_ act: Act) -> Set<TimerStatus.State>? {
        switch act {
        case .pause: [.counting]
        case .resume: [.paused]
        case .again, .stop: [.sounding]
        case .cancel: nil
        }
    }

    private func act(_ act: Act, _ id: String) async -> ToolReply {
        let missing = ToolReply(status: ToolReply.failed, text: "topo: no timer of Topo's with the id \(id)\n")
        guard let uuid = UUID(uuidString: id) else { return missing }
        // Asked of the list first, so an act AlarmKit refused is not said as no such timer, and an
        // act on the wrong state is said as that state.
        let read = now()
        do {
            let alarms = try await scheduler.alarms()
            guard let alarm = alarms.first(where: { $0.id == uuid }) else { return missing }
            if let needs = Self.needs(act), !needs.contains(alarm.state) {
                return .failed("topo: \(id) is \(alarm.state.rawValue): \(Self.why(act))\n")
            }
            switch act {
            case .pause: try await scheduler.pause(id: uuid)
            case .resume: try await scheduler.resume(id: uuid)
            case .again: try await scheduler.again(id: uuid)
            case .stop: try await scheduler.stop(id: uuid)
            case .cancel: try await scheduler.cancel(id: uuid)
            }
            if act == .cancel {
                if let sound = records.read(uuid)?.sound { sounds.remove(sound) }
                records.drop(uuid)
                sweep(keeping: alarms, readAt: read)
            }
        } catch {
            let still = act == .cancel || act == .stop ? ", which may still sound" : ""
            return .failed("topo: AlarmKit did not \(act.rawValue) \(id)\(still): \(error.localizedDescription)\n")
        }
        let done = ["pause": "paused", "resume": "resumed", "again": "counting again", "stop": "stopped", "cancel": "cancelled"][act.rawValue]!
        return .ok("\(done): \(id)\n")
    }

    private static func why(_ act: Act) -> String {
        switch act {
        case .pause: "only a counting timer pauses"
        case .resume: "only a paused timer resumes"
        case .again: "again starts the next countdown only while it sounds"
        case .stop: "stop is for one sounding; cancel takes it off"
        case .cancel: ""
        }
    }
}
