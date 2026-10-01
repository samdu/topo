#if os(watchOS)
import AppIntents
import CoreLocation
import RelevanceKit
import WidgetKit

extension WidgetRelevant {
    /// The context as RelevanceKit names it.
    var context: RelevantContext {
        switch self {
        case .dates(let from, let to):
            if #available(watchOS 26, *) { return .date(interval: DateInterval(start: from, end: to), kind: .default) }
            return .date(from: from, to: to)
        case .place(let place):
            switch place {
            case .home: return .location(inferred: .home)
            case .work: return .location(inferred: .work)
            case .school: return .location(inferred: .school)
            case .commute: return .location(inferred: .commute)
            }
        case .near(let latitude, let longitude, let radius):
            let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return .location(CLCircularRegion(center: centre, radius: radius, identifier: "topo-\(latitude),\(longitude),\(radius)"))
        case .sleep(let sleep):
            return .sleep(sleep == .bedtime ? .bedtime : .wakeup)
        case .headphones:
            return .hardware(headphones: .connected)
        }
    }
}

/// When each slot the watch holds matters, read from the slots' own `relevant` fields: every
/// slot, and every context it names, in the slots' order.
enum WatchRelevance {
    static func contexts(store: SurfaceStore? = SurfaceStore.shared(), at date: Date = Date()) -> [(slot: String, context: WidgetRelevant)] {
        guard let store else { return [] }
        return store.slots().flatMap { slot -> [(slot: String, context: WidgetRelevant)] in
            guard let reading = store.read(slot: slot), reading.readable else { return [] }
            if let until = reading.document.until, until <= date { return [] }
            return reading.document.relevant.map { (slot, $0) }
        }
    }

    /// For watchOS 10, where a placed widget's provider has no `relevance()`: the same contexts
    /// donated from the watch app, one `RelevantIntent` a slot and context.
    static func donate(store: SurfaceStore? = SurfaceStore.shared()) async {
        let intents = contexts(store: store).map {
            RelevantIntent(SurfaceConfiguration(slot: $0.slot), widgetKind: SurfaceStore.kind, relevance: $0.context.context)
        }
        try? await RelevantIntentManager.shared.updateRelevantIntents(intents)
    }
}
#endif
