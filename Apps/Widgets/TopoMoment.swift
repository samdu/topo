#if os(watchOS)
import AppIntents
import SwiftUI
import WidgetKit

@available(watchOS 26, *)
extension SurfaceEntry: RelevanceEntry {}

@available(watchOS 26, *)
struct MomentProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<SurfaceConfiguration> {
        WidgetRelevance(Self.offered().map {
            WidgetRelevanceAttribute(configuration: SurfaceConfiguration(slot: $0.slot), context: $0.context.context)
        })
    }

    func entry(configuration: SurfaceConfiguration, context: Context) async throws -> SurfaceEntry {
        Self.entry(slot: configuration.slot, at: Date())
    }

    /// The slots offered, each with the context it comes up in; `WidgetRelevance` keeps what it
    /// is handed where nothing can read it, so this is what the suite holds.
    static func offered(store: SurfaceStore? = SurfaceStore.shared(), at date: Date = Date()) -> [(slot: String, context: WidgetRelevant)] {
        WatchRelevance.contexts(store: store, at: date)
    }

    /// The card: the slot's `accessoryRectangular` tree, the default's when the slot has none.
    static func entry(slot: String?, store: SurfaceStore? = SurfaceStore.shared(), at date: Date) -> SurfaceEntry {
        SurfaceEntry(date: date, surface: SurfaceProvider.surface(slot: slot, family: .accessoryRectangular, at: date, store: store))
    }

    func placeholder(context: Context) -> SurfaceEntry {
        SurfaceEntry(date: Date(), surface: .drawn(node: .topo(.idle), context: WidgetContext(slot: SurfaceStore.defaultSlot, revision: 0,
                                                                                          family: .accessoryRectangular), tint: nil, tap: nil))
    }
}
#endif
