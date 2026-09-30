import AppIntents
import Foundation
import WidgetKit

/// What the extension draws for a placed widget, compiled into the app as well so the suites can
/// hold what an entry carries.
struct SurfaceEntry: TimelineEntry, Sendable {
    let date: Date
    let surface: Surface

    /// The drawn document's `relevance`, which orders the Smart Stack.
    var relevance: TimelineEntryRelevance? {
        guard case .drawn(_, let context, _, _) = surface, let score = context.relevance else { return nil }
        return TimelineEntryRelevance(score: Float(score))
    }
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

    #if os(watchOS)
    /// A watch face has no configuration sheet, so each slot the watch holds is offered as a
    /// widget of its own, the app's default first.
    func recommendations() -> [AppIntentRecommendation<SurfaceConfiguration>] {
        let slots = SurfaceStore.shared()?.slots() ?? []
        return [AppIntentRecommendation(intent: SurfaceConfiguration(), description: "Topo")]
            + slots.map { AppIntentRecommendation(intent: SurfaceConfiguration(slot: $0), description: $0) }
    }

    /// A placed `TopoSurface` rises in the Smart Stack when a context its slot names holds.
    @available(watchOS 11, *)
    func relevance() async -> WidgetRelevance<SurfaceConfiguration> {
        WidgetRelevance(WatchRelevance.contexts().map {
            WidgetRelevanceAttribute(configuration: SurfaceConfiguration(slot: $0.slot), context: $0.context.context)
        })
    }
    #endif

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
                                        privateText: isDefault && !family.isAccessory,
                                        failed: store.failed(slot: name, revision: document.revision),
                                        relevance: document.relevance)
            return .drawn(node: node, context: context, tint: document.tint, tap: document.tap)
        }
        return .signedOut
    }
}
