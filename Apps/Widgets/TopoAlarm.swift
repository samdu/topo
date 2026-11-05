#if os(iOS)
import AlarmKit
import SwiftUI
import WidgetKit

/// The countdown of a timer the mind sets with `topo timer` (docs/widgets.md, *Timers*): AlarmKit
/// expects this configuration for its alarms' attributes, and without it may dismiss an alarm and
/// fail to sound. The alert itself is the system's; this draws the label and the time left, from
/// the state AlarmKit keeps (`AlarmPresentationState`), on the lock screen and in the island.
@available(iOS 26, *)
struct TopoAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TopoAlarmMetadata>.self) { context in
            HStack {
                Text(Self.label(context.attributes))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Self.remaining(context.state.mode)
                    .font(.system(.title, design: .rounded).monospacedDigit())
            }
            .padding()
            .foregroundStyle(Theme.text)
            .activitySystemActionForegroundColor(Theme.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(Self.label(context.attributes)).lineLimit(1)
                        Spacer()
                        Self.remaining(context.state.mode).font(.system(.title2, design: .rounded).monospacedDigit())
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(Theme.primary)
            } compactTrailing: {
                Self.remaining(context.state.mode)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: ActivityRegionView.compactBound.width)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Theme.primary)
            }
            .keylineTint(Theme.primary)
        }
    }

    static func label(_ attributes: AlarmAttributes<TopoAlarmMetadata>) -> String {
        attributes.metadata?.label ?? "Timer"
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
            Text(Duration.seconds(paused.totalCountdownDuration - paused.previouslyElapsedDuration),
                 format: .time(pattern: .minuteSecond))
        default:
            EmptyView()
        }
    }
}
#endif
