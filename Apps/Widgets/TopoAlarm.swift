#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

/// The countdown of a timer the mind sets with `topo timer` (docs/widgets.md, *Timers*): AlarmKit
/// expects this configuration for its alarms' attributes, and without it may dismiss an alarm and
/// fail to sound. The alert itself is the system's; this draws each other state from what AlarmKit
/// keeps (`AlarmPresentationState`), on the lock screen and in the island: counting, with the
/// countdown's title, the time left and the Pause and Cancel the mind asked for; paused, with the
/// paused title, the time held, Resume and Cancel; and sounding, with the alert's title. AlarmKit's
/// own Pause and Resume show only in the system's templated presentation, so these are the widget's
/// buttons (`TimerControlIntent`), drawn in the words, symbols and colours the mind gave them.
struct TopoAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TopoAlarmMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Self.title(context.attributes, context.state.mode))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Self.remaining(context.state.mode)
                        .font(.system(.title, design: .rounded).monospacedDigit())
                }
                Self.controls(context.attributes, context.state)
            }
            .padding()
            .foregroundStyle(Theme.text)
            .activitySystemActionForegroundColor(Theme.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Text(Self.title(context.attributes, context.state.mode)).lineLimit(1)
                            Spacer()
                            Self.remaining(context.state.mode).font(.system(.title2, design: .rounded).monospacedDigit())
                        }
                        Self.controls(context.attributes, context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: Self.glyph(context.state.mode)).foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                Self.remaining(context.state.mode)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: ActivityRegionView.compactBound.width)
            } minimal: {
                Image(systemName: Self.glyph(context.state.mode)).foregroundStyle(context.attributes.tintColor)
            }
            .keylineTint(context.attributes.tintColor)
        }
    }

    static func label(_ attributes: AlarmAttributes<TopoAlarmMetadata>) -> String {
        attributes.metadata?.label ?? "Timer"
    }

    /// What each state says: the countdown's title, the paused title, the alert's title.
    static func title(_ attributes: AlarmAttributes<TopoAlarmMetadata>, _ mode: AlarmPresentationState.Mode) -> String {
        let presentation = attributes.presentation
        let resource: LocalizedStringResource? = switch mode {
        case .countdown: presentation.countdown?.title
        case .paused: presentation.paused?.title
        case .alert: presentation.alert.title
        @unknown default: nil
        }
        return resource.map { String(localized: $0) } ?? label(attributes)
    }

    static func glyph(_ mode: AlarmPresentationState.Mode) -> String {
        switch mode {
        case .paused: "pause.circle"
        case .alert: "alarm"
        default: "timer"
        }
    }

    /// The time left, counted by the system with no update: a countdown to its fire date, a paused
    /// one held at what is left, and nothing while it sounds, since the alert is the system's.
    @ViewBuilder
    static func remaining(_ mode: AlarmPresentationState.Mode) -> some View {
        switch mode {
        case let .countdown(countdown):
            Text(timerInterval: AlarmCountdown.range(now: .now, fires: countdown.fireDate), countsDown: true)
                .multilineTextAlignment(.trailing)
        case let .paused(paused):
            Text(Duration.seconds(AlarmCountdown.left(total: paused.totalCountdownDuration, elapsed: paused.previouslyElapsedDuration)),
                 format: .time(pattern: .minuteSecond))
        default:
            EmptyView()
        }
    }

    /// Pause while counting, Resume while paused, and Cancel in both, each only where the mind
    /// asked for it; nothing while it sounds, when the system's alert has its own.
    @ViewBuilder
    static func controls(_ attributes: AlarmAttributes<TopoAlarmMetadata>, _ state: AlarmPresentationState) -> some View {
        let presentation = attributes.presentation
        let toggle: (AlarmButton, TimerAction)? = switch state.mode {
        case .countdown: presentation.countdown?.pauseButton.map { ($0, .pause) }
        case .paused: presentation.paused.map { ($0.resumeButton, .resume) }
        default: nil
        }
        let counting = switch state.mode { case .countdown, .paused: true; default: false }
        let cancel = counting ? attributes.metadata?.cancel : nil
        if toggle != nil || cancel != nil {
            HStack {
                if let (button, action) = toggle {
                    Button(intent: TimerControlIntent(alarm: state.alarmID, action: action)) {
                        Label(String(localized: button.text), systemImage: button.systemImageName)
                            .foregroundStyle(button.textColor)
                    }
                    .tint(attributes.tintColor)
                }
                Spacer()
                if let cancel {
                    Button(intent: TimerControlIntent(alarm: state.alarmID, action: .cancel)) {
                        Label(cancel.text, systemImage: cancel.icon)
                            .foregroundStyle(cancel.colour.flatMap(WidgetColour.init(option:))?.color ?? Theme.onPrimary)
                    }
                    .tint(attributes.tintColor)
                }
            }
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
        }
    }
}
#endif
