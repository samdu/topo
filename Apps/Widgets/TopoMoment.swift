#if os(watchOS)
import AppIntents
import SwiftUI
import WidgetKit

/// `TopoMoment`: the Smart Stack's own card for a slot, shown when a context the slot's `relevant`
/// names holds, whether or not the person placed anything. The mind decides both what the card is
/// (the slot's `accessoryRectangular` tree) and when it comes up.
@available(watchOS 26, *)
struct TopoMomentWidget: Widget {
    static let kind = "TopoMoment"

    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: Self.kind, provider: MomentProvider()) { entry in
            SurfaceEntryView(entry: entry)
        }
        .configurationDisplayName("Topo")
        .description("What Topo thinks matters now.")
    }
}

@available(watchOS 26, *)
extension SurfaceEntry: RelevanceEntry {}

@available(watchOS 26, *)
struct MomentProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<SurfaceConfiguration> {
        WidgetRelevance(WatchRelevance.contexts().map {
            WidgetRelevanceAttribute(configuration: SurfaceConfiguration(slot: $0.slot), context: $0.context.context)
        })
    }

    func entry(configuration: SurfaceConfiguration, context: Context) async throws -> SurfaceEntry {
        let now = Date()
        return SurfaceEntry(date: now, surface: SurfaceProvider.surface(slot: configuration.slot, family: .accessoryRectangular, at: now))
    }

    func placeholder(context: Context) -> SurfaceEntry {
        SurfaceEntry(date: Date(), surface: .drawn(node: .topo(.idle), context: WidgetContext(slot: SurfaceStore.defaultSlot, revision: 0,
                                                                                          family: .accessoryRectangular), tint: nil, tap: nil))
    }
}
#endif
