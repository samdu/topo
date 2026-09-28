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

/// The one thing a placed widget is configured with: which of the mind's slots it shows.
struct SurfaceConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Topo"
    static let description = IntentDescription("Which of Topo's widgets this one shows.")

    @Parameter(title: "Widget", optionsProvider: SlotOptions())
    var slot: String?

    init() {}
}

/// The slots in the app group, listed as the person places a widget.
struct SlotOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        SurfaceStore.shared()?.slots() ?? []
    }
}

struct SurfaceEntry: TimelineEntry {
    let date: Date
    let surface: Surface
}

/// What one entry draws. Only the tree for the entry's family is carried, so a lock-screen entry
/// of the default holds nothing the default kept off the lock screen.
enum Surface: Sendable {
    case drawn(node: WidgetNode, context: WidgetContext, tint: WidgetColour?, tap: WidgetAction?)
    /// Nothing written: the phone is signed out, or has never been signed in.
    case signedOut
}

struct SurfaceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SurfaceEntry {
        SurfaceEntry(date: Date(), surface: .drawn(node: .topo(.idle), context: WidgetContext(slot: SurfaceStore.defaultSlot, revision: 0,
                                                                                          family: .default), tint: nil, tap: nil))
    }

    func snapshot(for configuration: SurfaceConfiguration, in context: Context) async -> SurfaceEntry {
        SurfaceEntry(date: Date(), surface: Self.surface(slot: configuration.slot, family: WidgetFamilyName(context.family), at: Date()))
    }

    func timeline(for configuration: SurfaceConfiguration, in context: Context) async -> Timeline<SurfaceEntry> {
        Self.timeline(slot: configuration.slot, family: WidgetFamilyName(context.family), now: Date())
    }

    /// One entry now, and one at the slot's `until` when it has one, after which the default is
    /// drawn. A document with no date is read again only when the app reloads it.
    static func timeline(slot: String?, family: WidgetFamilyName, now: Date,
                         store: SurfaceStore? = SurfaceStore.shared()) -> Timeline<SurfaceEntry> {
        let current = SurfaceEntry(date: now, surface: surface(slot: slot, family: family, at: now, store: store))
        guard let slot, let until = store?.read(slot: slot)?.document.until, until > now else {
            return Timeline(entries: [current], policy: .never)
        }
        let after = SurfaceEntry(date: until, surface: surface(slot: slot, family: family, at: until, store: store))
        return Timeline(entries: [current, after], policy: .after(until))
    }

    /// The slot's tree for `family` while it has one and its `until` has not passed; the default's
    /// otherwise; signed out when neither is there.
    static func surface(slot: String?, family: WidgetFamilyName, at date: Date,
                        store: SurfaceStore? = SurfaceStore.shared()) -> Surface {
        guard let store else { return .signedOut }
        for name in [slot, SurfaceStore.defaultSlot].compactMap({ $0 }) {
            guard let reading = store.read(slot: name), reading.readable else { continue }
            let document = reading.document
            if let until = document.until, until <= date { continue }
            guard let node = document.tree(for: family) else { continue }
            var images: [String: Data] = [:]
            node.walk { each in
                if case .image(let image) = each, images[image.name] == nil {
                    images[image.name] = store.imageData(slot: name, name: image.name)
                }
            }
            let isDefault = name == SurfaceStore.defaultSlot
            let context = WidgetContext(slot: name, revision: document.revision, family: family, images: images,
                                        privateText: isDefault && !family.isAccessory)
            return .drawn(node: node, context: context, tint: document.tint, tap: document.tap)
        }
        return .signedOut
    }
}

extension WidgetFamilyName {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .systemSmall
        case .systemMedium: self = .systemMedium
        case .systemLarge, .systemExtraLarge: self = .systemLarge
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryRectangular: self = .accessoryRectangular
        case .accessoryInline: self = .accessoryInline
        default: self = .default
        }
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
        case .turn(let say): WidgetURL.cue(slot: context.slot, control: "tap", revision: context.revision, say: say)
        case .run: nil
        }
    }
}
