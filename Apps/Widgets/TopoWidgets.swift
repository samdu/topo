import AppIntents
import SwiftUI
import WidgetKit

/// The widget extension: one kind, `TopoSurface`, which draws one of the mind's slots — the one
/// the person picked when they placed it — or the app's default where none is picked, the slot is
/// gone, or its `until` has passed. It reads the app group and nothing else: never the tool
/// service, the guest or the network.
#if os(watchOS)
/// The watch's extension, `TopoWatchWidgets`: the placeable `TopoSurface` for the face's
/// complications, and `TopoMoment`, which the Smart Stack shows unplaced when a slot says it
/// matters. It reads the watch's group, which the watch app fills from the slots' records, and
/// fetches nothing.
@main
struct TopoWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TopoSurfaceWidget()
        if #available(watchOS 26, *) { TopoMomentWidget() }
    }
}

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
#else
@main
struct TopoWidgetBundle: WidgetBundle {
    var body: some Widget {
        TopoSurfaceWidget()
    }
}
#endif

struct TopoSurfaceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SurfaceStore.kind, intent: SurfaceConfiguration.self, provider: SurfaceProvider()) { entry in
            SurfaceEntryView(entry: entry)
        }
        .configurationDisplayName("Topo")
        .description("A widget Topo made for you, or what Topo last said.")
        .supportedFamilies(Self.families)
    }

    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
    #else
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge,
                                           .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #endif
}

struct SurfaceEntryView: View {
    let entry: SurfaceEntry

    var body: some View {
        switch entry.surface {
        case .drawn(let node, let context, let tint, let tap):
            WidgetNodeView(node: node, context: context)
                .widgetURL(tap.flatMap { Self.url($0, context) })
                .containerBackground(for: .widget) { (tint?.color ?? Theme.surface) }
        case .signedOut:
            VStack(spacing: 6) {
                OctopusMark().frame(maxWidth: 44, maxHeight: 44)
                Text(Self.signedOut).font(.caption).multilineTextAlignment(.center)
            }
            .containerBackground(for: .widget) { Theme.surface }
        }
    }

    /// What a widget says with nothing to draw: on the phone, no login; on the watch, an app never
    /// opened to fetch anything.
    #if os(watchOS)
    static let signedOut = "Open Topo"
    #else
    static let signedOut = "Sign in on your phone"
    #endif

    static func url(_ action: WidgetAction, _ context: WidgetContext) -> URL? {
        switch action {
        case .open: WidgetURL.open
        case .turn: WidgetURL.cue(slot: context.slot, control: WidgetDocument.wholeTap, revision: context.revision)
        case .run: nil
        }
    }
}
