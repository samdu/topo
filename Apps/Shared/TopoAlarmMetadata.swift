#if os(iOS)
import AlarmKit

/// What a timer of Topo's carries to the widget extension, which draws its countdown on the lock
/// screen and in the Dynamic Island (`TopoAlarmWidget`): the label the alert and the countdown say.
@available(iOS 26, *)
nonisolated struct TopoAlarmMetadata: AlarmMetadata {
    var label: String
}
#endif
