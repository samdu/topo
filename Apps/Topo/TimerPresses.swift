import AlarmKit
import AppIntents
import Foundation
import os

/// Which of a timer's buttons hands Topo a turn.
enum TimerButton: String, Sendable {
    /// The alert's second button (`--tell`).
    case second
    /// The system's Stop (`--on-stop`).
    case stop
}

/// What AlarmKit runs when a timer's `--tell` button or its Stop is pressed: the alarm's id and
/// which button, never the words, which the app reads from the alarm's record. A
/// `LiveActivityIntent`, so it runs in the app's process, launched into the background when it is
/// not running, and with the default authentication policy, so a press on the lock screen asks
/// for no Face ID: the words are the mind's own, kept when it set the timer, and a press can only
/// send them.
struct TimerPressIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Press a button on Topo's timer"
    static let isDiscoverable = false

    @Parameter(title: "Alarm") var alarm: String
    @Parameter(title: "Button") var button: String
    /// Whether the button also starts the next countdown (AlarmKit's `.countdown`), which the app
    /// then leaves to AlarmKit; one that does not (`.custom`) leaves the alarm sounding.
    @Parameter(title: "Restarts") var restarts: Bool

    init() {}

    init(alarm: UUID, button: TimerButton, restarts: Bool = false) {
        self.alarm = alarm.uuidString
        self.button = button.rawValue
        self.restarts = restarts
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarm), let button = TimerButton(rawValue: button) {
            await TimerPresses.press(id, button, restarts: restarts)
        }
        return .result()
    }
}

/// A timer's button handing Topo its turn. The words go the way a Shortcut's do: kept in
/// `ShareStore` under a nonce minted here and the login the alarm was set under, which the store
/// refuses unless it is the login its door names, and put on the line by the drain, so one press
/// is one turn however often it is drained, and a press after a sign-out sends nothing. The press
/// waits for its turn to reach the log, bounded, as a background Shortcut does.
@MainActor
enum TimerPresses {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "timer")

    /// What a press came to, for the suites.
    enum Outcome: Equatable {
        case kept(nonce: String)
        /// No record, or none of words for that button.
        case nothing
        /// Stop's intent run by the app's own stop of a `.custom` press, which is that press's turn.
        case echo
        case refused(ShareRefusal)
    }

    /// When the app last stopped an alarm for a `.custom` press, so a Stop intent that stop sets
    /// off is not taken for the person's own press of Stop.
    private static var stopping: [UUID: ContinuousClock.Instant] = [:]
    static let echoWindow: Duration = .seconds(10)

    @discardableResult
    static func press(_ id: UUID, _ button: TimerButton, restarts: Bool = false, records: TimerRecords = .shared,
                      scheduler: any AlarmScheduler = TimerRecords.scheduler, store: ShareStore? = ShareStore.shared(),
                      drain: (@MainActor () async -> Void)? = ShortcutIntents.drain,
                      landed: (@MainActor (String) -> Bool)? = ShortcutIntents.landed,
                      bound: Duration = ShortcutIntents.bound, nonce: String = UUID().uuidString, at time: Date = Date()) async -> Outcome {
        let record = records.read(id)
        // `.custom` leaves the alarm sounding, so a button that only tells Topo stops it while it
        // still sounds; one that also starts the next countdown (`.countdown`) is AlarmKit's to
        // restart, and a stop would end the countdown it started.
        if button == .stop, let stopped = stopping[id], ContinuousClock.now - stopped < echoWindow {
            stopping[id] = nil
            return .echo
        }
        if button == .second, !restarts {
            do {
                if try await scheduler.alarms().first(where: { $0.id == id })?.state == .sounding {
                    stopping[id] = .now
                    try await scheduler.stop(id: id)
                }
            } catch {
                log.error("a timer's button could not stop its alarm: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let record, let words = button == .second ? record.tell : record.onStop, let login = record.login else {
            log.error("a timer's \(button.rawValue, privacy: .public) button has no words kept: nothing sent")
            return .nothing
        }
        guard let store else { return .refused(.failed) }
        let name = button == .second ? record.second ?? "second" : "Stop"
        let share = Share(nonce: nonce, login: login, time: time, kind: .timer, note: "", text: words,
                          from: "\"\(record.label)\" timer's \(name)")
        do {
            try store.keep(share)
        } catch {
            // Signed out, or another login since: the words were kept for that one.
            log.error("a timer's press was not kept: \(String(describing: error), privacy: .public)")
            return .refused(error)
        }
        if let drain { Task { await drain() } }
        if let landed {
            let clock = ContinuousClock()
            let deadline = clock.now + bound
            while !landed(nonce), clock.now < deadline {
                try? await Task.sleep(for: ShortcutIntents.glance)
            }
        }
        return .kept(nonce: nonce)
    }
}
