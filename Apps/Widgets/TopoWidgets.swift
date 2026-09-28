import AppIntents
import SwiftUI
import WidgetKit

/// The widget extension: one kind, `TopoSurface`, which draws one of the mind's slots — the one
/// the person picked when they placed it — or the app's default where none is picked, the slot is
/// gone, or its `until` has passed. It reads the app group and nothing else: never the tool
/// service, the guest or the network.
@main
struct TopoWidgetBundle: WidgetBundle {
    var body: some Widget {
        TopoSurfaceWidget()
    }
}

struct TopoSurfaceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SurfaceStore.kind, intent: SurfaceConfiguration.self, provider: SurfaceProvider()) { entry in
            SurfaceEntryView(entry: entry)
        }
        .configurationDisplayName("Topo")
        .description("A widget Topo made for you, or what Topo last said.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
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
                Text("Sign in on your phone").font(.caption).multilineTextAlignment(.center)
            }
            .containerBackground(for: .widget) { Theme.surface }
        }
    }

    static func url(_ action: WidgetAction, _ context: WidgetContext) -> URL? {
        switch action {
        case .open: WidgetURL.open
        case .turn: WidgetURL.cue(slot: context.slot, control: "tap", revision: context.revision)
        case .run: nil
        }
    }
}
