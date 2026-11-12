#if os(iOS)
import AlarmKit
import AppIntents
import Foundation

/// What a timer of Topo's carries to the widget extension, which draws its countdown on the lock
/// screen and in the Dynamic Island (`TopoAlarmWidget`): the label it draws, and the Cancel button
/// the mind asked for, which is the widget's own control and not one of AlarmKit's presentation.
/// The system's own alert says the alert presentation's title.
nonisolated struct TopoAlarmMetadata: AlarmMetadata {
    var label: String
    /// A Cancel button beside the countdown and the paused time. Absent on an alarm set before
    /// the mind could ask for one, which decodes as none.
    var cancel: Control?

    struct Control: Codable, Hashable, Sendable {
        var text: String
        var icon: String
        /// The colour of its words as `topo timer --button-color` reads it: a `Theme` token, a hex,
        /// or a light and a dark hex as `LIGHT/DARK`.
        var colour: String?
    }
}

/// The span a countdown draws, from now to its fire date. One drawn once that date has passed,
/// before the alert's state lands, is at zero rather than a range whose end is before its start,
/// which traps.
nonisolated enum AlarmCountdown {
    static func range(now: Date, fires: Date) -> ClosedRange<Date> { now...max(now, fires) }

    /// What is left of a paused countdown, never below zero.
    static func left(total: TimeInterval, elapsed: TimeInterval) -> TimeInterval { max(0, total - elapsed) }
}

/// What a button the widget draws on a timer's countdown does.
enum TimerAction: String, Sendable {
    case pause, resume, cancel
}

/// The app's side of those buttons, set by `TopoApp` at launch, which the system finishes before
/// an intent it launched the app for runs. Nil in the extension, which never runs the intent.
enum TimerIntents {
    @MainActor static var control: (@MainActor (UUID, TimerAction) async -> Void)?
}

/// A Pause, Resume or Cancel button on a timer's countdown. A `LiveActivityIntent`, so it runs in
/// the app's process, launched into the background if it is not running, where `AlarmManager`
/// answers for the app's own alarms; it keeps the default authentication policy, so a press on
/// the lock screen asks for no Face ID, as the system's own timer's buttons do not.
struct TimerControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Topo's timer"
    static let isDiscoverable = false

    @Parameter(title: "Alarm") var alarm: String
    @Parameter(title: "Action") var action: String

    init() {}

    init(alarm: UUID, action: TimerAction) {
        self.alarm = alarm.uuidString
        self.action = action.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarm), let action = TimerAction(rawValue: action) {
            await TimerIntents.control?(id, action)
        }
        return .result()
    }
}
#endif
