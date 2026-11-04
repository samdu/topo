#if os(iOS)
import AlarmKit

/// What a timer of Topo's carries to the widget extension, which draws its countdown on the lock
/// screen and in the Dynamic Island (`TopoAlarmWidget`): the label it draws. The system's own alert
/// says the presentation's title, which is the same label.
@available(iOS 26, *)
nonisolated struct TopoAlarmMetadata: AlarmMetadata {
    var label: String
}
#endif
