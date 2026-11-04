#if os(iOS)
import AlarmKit
import Foundation

/// What a timer of Topo's carries to the widget extension, which draws its countdown on the lock
/// screen and in the Dynamic Island (`TopoAlarmWidget`): the label it draws. The system's own alert
/// says the presentation's title, which is the same label.
@available(iOS 26, *)
nonisolated struct TopoAlarmMetadata: AlarmMetadata {
    var label: String
}

/// The span a countdown draws, from now to its fire date. One drawn once that date has passed,
/// before the alert's state lands, is at zero rather than a range whose end is before its start,
/// which traps.
nonisolated enum AlarmCountdown {
    static func range(now: Date, fires: Date) -> ClosedRange<Date> { now...max(now, fires) }
}
#endif
