#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity the mind starts with `topo activity` (docs/widgets.md, *Live Activities*): one
/// type, drawn from its state alone — the extension reads no app group, no network and no tool
/// service for it. Each region draws the layout's tree for it where there is one, else the
/// tracker design, else the mark (`ActivityRegionView`).
struct TopoActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TopoActivityAttributes.self) { context in
            ActivityRegionView(region: .lockScreen, slot: context.attributes.slot, state: context.state, stale: context.isStale)
                .padding()
                .activityBackgroundTint(Self.tint(context.state))
                .activitySystemActionForegroundColor(Theme.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityRegionView(region: .islandExpanded, slot: context.attributes.slot, state: context.state, stale: context.isStale)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                ActivityRegionView(region: .islandCompactLeading, slot: context.attributes.slot, state: context.state, stale: context.isStale)
            } compactTrailing: {
                ActivityRegionView(region: .islandCompactTrailing, slot: context.attributes.slot, state: context.state, stale: context.isStale)
            } minimal: {
                ActivityRegionView(region: .islandMinimal, slot: context.attributes.slot, state: context.state, stale: context.isStale)
            }
            .keylineTint(Self.tint(context.state))
        }
    }

    /// The document's tint, where the layout gave one; otherwise the system's own material.
    static func tint(_ state: ActivityState) -> Color? {
        state.layout.map(ActivityLayout.read)?.tint?.color
    }
}
#endif
