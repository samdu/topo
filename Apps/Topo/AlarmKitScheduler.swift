import ActivityKit
import AlarmKit
import Foundation
import os
import SwiftUI
import TopoTools

/// `AlarmScheduler` over AlarmKit. `schedule` and the prompt are asynchronous and called as they
/// are; `alarms`, `pause`, `resume`, `countdown`, `stop` and `cancel` are synchronous calls into
/// the system, reached only through `Confined`, whose queue is not the cooperative pool.
@available(iOS 26, *)
struct AlarmKitScheduler: AlarmScheduler {
    private let manager = Confined(AlarmManager.shared, label: "zone.hexagon.topo.alarms")

    var available: Bool { true }
    var authorizer: (any Authorizer)? { AlarmAuthorizer() }

    func schedule(id: UUID, plan: TimerPlan) async throws {
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: Self.configuration(id: id, plan: plan))
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw AlarmLimit()
        }
    }

    /// The plan as AlarmKit's configuration: the presentation of each state, the durations, the
    /// schedule, the intents a press runs, and the sound.
    static func configuration(id: UUID, plan: TimerPlan) -> AlarmManager.AlarmConfiguration<TopoAlarmMetadata> {
        let timing = timing(plan)
        return AlarmManager.AlarmConfiguration(
            countdownDuration: timing.duration, schedule: timing.schedule, attributes: attributes(plan),
            stopIntent: plan.tellsOnStop ? TimerPressIntent(alarm: id, button: .stop) : nil,
            secondaryIntent: plan.tells ? TimerPressIntent(alarm: id, button: .second, restarts: plan.again != nil) : nil,
            sound: plan.sound.map { .named($0) } ?? .default)
    }

    static func attributes(_ plan: TimerPlan) -> AlarmAttributes<TopoAlarmMetadata> {
        let colour = plan.buttonColor.color
        func button(_ button: TimerPlan.Button) -> AlarmButton {
            AlarmButton(text: LocalizedStringResource(stringLiteral: button.text), textColor: colour, systemImageName: button.icon)
        }
        func words(_ text: String) -> LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }

        // `.countdown` restarts the countdown and still runs the intent, so a button that does
        // both is `.countdown` with an intent; one that only tells Topo is `.custom`.
        let behaviour: AlarmPresentation.Alert.SecondaryButtonBehavior? =
            plan.second == nil ? nil : plan.again != nil ? .countdown : .custom
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: words(plan.title), secondaryButton: plan.second.map(button),
                                            secondaryButtonBehavior: behaviour)
        } else {
            alert = AlarmPresentation.Alert(title: words(plan.title),
                                            stopButton: AlarmButton(text: "Stop", textColor: colour, systemImageName: "stop.circle"),
                                            secondaryButton: plan.second.map(button), secondaryButtonBehavior: behaviour)
        }
        let countdown = plan.countsDown ? AlarmPresentation.Countdown(title: words(plan.label), pauseButton: plan.pause.map(button)) : nil
        let paused = plan.resume.map { AlarmPresentation.Paused(title: words(plan.pausedTitle), resumeButton: button($0)) }
        let metadata = TopoAlarmMetadata(label: plan.label, cancel: plan.cancel.map { .init(text: $0.text, icon: $0.icon, colour: plan.buttonColor.option) })
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert, countdown: countdown, paused: paused),
                               metadata: metadata, tintColor: plan.tint.color)
    }

    /// The countdown's durations (the first, and the one the second button starts) and the schedule.
    static func timing(_ plan: TimerPlan) -> (duration: Alarm.CountdownDuration?, schedule: Alarm.Schedule?) {
        switch plan.when {
        case let .after(span):
            return (.init(preAlert: span, postAlert: plan.again), nil)
        case let .on(date):
            return (plan.again.map { .init(preAlert: nil, postAlert: $0) }, .fixed(date))
        case let .at(hour, minute, days):
            return (plan.again.map { .init(preAlert: nil, postAlert: $0) },
                    .relative(.init(time: .init(hour: hour, minute: minute), repeats: days.isEmpty ? .never : .weekly(days))))
        }
    }

    func alarms() async throws -> [TimerStatus] {
        // The countdown's end and a pause's time left are the Live Activity's, which AlarmKit
        // keeps for every alarm counting, paused or sounding.
        let modes = Dictionary(Activity<AlarmAttributes<TopoAlarmMetadata>>.activities.map { ($0.content.state.alarmID, $0.content.state.mode) },
                               uniquingKeysWith: { first, _ in first })
        return try await manager.run { manager, _ in
            try manager.alarms.map { alarm in
                var status = TimerStatus(id: alarm.id, state: Self.state(alarm.state), when: alarm.schedule.map(Self.when))
                switch modes[alarm.id] {
                case let .countdown(countdown)?: status.fires = countdown.fireDate
                case let .paused(paused)?:
                    status.left = AlarmCountdown.left(total: paused.totalCountdownDuration, elapsed: paused.previouslyElapsedDuration)
                default: break
                }
                return status
            }
        }
    }

    func pause(id: UUID) async throws { try await manager.run { manager, _ in try manager.pause(id: id) } }
    func resume(id: UUID) async throws { try await manager.run { manager, _ in try manager.resume(id: id) } }
    func again(id: UUID) async throws { try await manager.run { manager, _ in try manager.countdown(id: id) } }
    func stop(id: UUID) async throws { try await manager.run { manager, _ in try manager.stop(id: id) } }
    func cancel(id: UUID) async throws { try await manager.run { manager, _ in try manager.cancel(id: id) } }

    static func state(_ state: Alarm.State) -> TimerStatus.State {
        switch state {
        case .scheduled: .set
        case .countdown: .counting
        case .paused: .paused
        case .alerting: .sounding
        @unknown default: .unknown
        }
    }

    static func when(_ schedule: Alarm.Schedule) -> TimerPlan.When {
        switch schedule {
        case let .fixed(date): return .on(date)
        case let .relative(relative):
            let days: [Locale.Weekday] = if case let .weekly(days) = relative.repeats { days } else { [] }
            return .at(hour: relative.time.hour, minute: relative.time.minute, days: days)
        @unknown default: return .on(.distantFuture)
        }
    }
}

/// AlarmKit's permission, asked at a timer's start and nowhere else (`PermissionBroker`).
@available(iOS 26, *)
struct AlarmAuthorizer: ThrowingPrompt {
    let name = "Alarms"

    func access() async -> Access {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .denied
        }
    }

    func request() async -> Bool { (try? await prompt()) == .granted }

    func prompt() async throws -> Access {
        switch try await AlarmManager.shared.requestAuthorization() {
        case .notDetermined: .undetermined
        case .authorized: .granted
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

/// The widget's Pause, Resume and Cancel, run in the app (`TimerControlIntent`). A press acts on
/// AlarmKit's alarm as `topo timer` would; one AlarmKit refuses changes nothing, and the countdown
/// stays as AlarmKit draws it, which is what the person sees.
@MainActor
enum TimerControls {
    static func act(_ id: UUID, _ action: TimerAction, scheduler: any AlarmScheduler = TimerRecords.scheduler,
                    records: TimerRecords = .shared) async {
        do {
            switch action {
            case .pause: try await scheduler.pause(id: id)
            case .resume: try await scheduler.resume(id: id)
            case .cancel:
                try await scheduler.cancel(id: id)
                if let sound = records.read(id)?.sound { TimerSounds().remove(sound) }
                records.drop(id)
            }
        } catch {
            Logger(subsystem: "zone.hexagon.topo", category: "timer").error("timer \(action.rawValue, privacy: .public) refused by AlarmKit: \(error.localizedDescription, privacy: .public)")
        }
    }
}
