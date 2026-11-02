#if os(iOS)
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A Live Activity the mind puts on the lock screen and in the Dynamic Island with `topo activity`
/// (docs/widgets.md, *Live Activities*). One document, two things it can carry: a progress tracker
/// (`tracker`, the decisions pane's JSON, or `poll`, where the app fetches it from), drawn by the
/// tracker design in every region; and `families`, a node tree per region in `topo widget`'s
/// grammar, drawn in place of the design where one is given. Everything in it shows on a locked
/// phone, so every region is read with the lock screen's text budget, and an activity draws no
/// control and no image.
///
/// ActivityKit holds an activity's attributes and content state together under 4 KB, so the state
/// carries not the tracker but `TrackerCard`, a bounded projection of it, and the budget is judged
/// over the encoded attributes and state together at every start and update (`ActivityPayload`).
struct ActivityDocument: Equatable, Sendable {
    static let version = 1
    /// What ActivityKit allows the attributes and the state together, with a margin under 4 096
    /// for its own encoding.
    static let payloadLimit = 4_000
    static let pollLimit = 512
    /// How far ahead `until` may be: as long as the system shows an activity at all.
    static let untilLimit: TimeInterval = 12 * 3600
    static let byteLimit = 16 * 1024

    var tracker: ProgressTracker?
    /// Where the tracker is fetched from, at the start and every `ActivityKeeper.interval` while
    /// Topo runs.
    var poll: URL?
    var regions: [ActivityRegion: WidgetNode] = [:]
    var tint: WidgetColour?
    /// When the activity is over: its stale date, and the app ends it then while it runs, or at
    /// its next return to the screen.
    var until: Date?
    /// How prominent among the activities on the phone, 0 to 100.
    var relevance: Double?

    var layout: ActivityLayout { ActivityLayout(regions: regions, tint: tint) }

    /// The document carries something for the lock screen to draw.
    var drawsSomething: Bool { tracker != nil || poll != nil || regions[.lockScreen] != nil }

    // MARK: Reading

    enum State: Equatable, Sendable {
        case read
        case unreadable(String)
    }

    struct Reading: Equatable, Sendable {
        var document: ActivityDocument
        var state: State
        var notes: [String] = []
        var readable: Bool { if case .read = state { true } else { false } }
    }

    static let keys: Set<String> = ["version", "tracker", "poll", "families", "tint", "until", "relevance"]

    /// The mind's JSON, judged field by field: a bad field costs itself and no other. Unreadable
    /// only when it is not a document at all or, at a start, draws nothing on the lock screen; an
    /// `update` stands over a state that already draws, so it may carry anything.
    static func read(_ text: String, now: Date = Date(), update: Bool = false) -> Reading {
        let empty = ActivityDocument()
        guard text.utf8.count <= byteLimit else {
            return Reading(document: empty, state: .unreadable("is \(text.utf8.count) bytes, over the \(byteLimit / 1024) KB a document holds"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return Reading(document: empty, state: .unreadable("is not JSON"))
        }
        guard let root = parsed as? [String: Any] else {
            return Reading(document: empty, state: .unreadable("is not a JSON object"))
        }
        if let version = root["version"] {
            guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(Self.version) else {
                return Reading(document: empty, state: .unreadable("is version \(version), and this app reads version \(Self.version)"))
            }
        }
        let reader = WidgetReader(source: .mind)
        var document = ActivityDocument()
        for key in root.keys.sorted() where !keys.contains(key) { reader.note(key, "is not a field of an activity") }
        if let raw = root["tracker"] {
            let reading = ProgressTracker.read(raw, now: now)
            document.tracker = reading.tracker
            reader.append(notes: reading.notes)
        }
        if let raw = root["poll"] {
            if let text = raw as? String, text.count <= pollLimit, let url = URL(string: text),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
               let host = url.host, !host.isEmpty {
                document.poll = url
            } else {
                reader.note("poll", "is not an http or https URL with a host, of at most \(pollLimit) characters")
            }
        }
        if let tint = root["tint"] {
            if let colour = WidgetColour(tint) { document.tint = colour } else { reader.note("tint", WidgetReader.notAColour) }
        }
        if let raw = root["until"] {
            if let date = reader.date(raw) {
                if date <= now { reader.note("until", "has passed") }
                else if date.timeIntervalSince(now) > untilLimit { reader.note("until", "is more than 12 hours ahead, as long as the system shows an activity") }
                else { document.until = date }
            } else {
                reader.note("until", WidgetReader.notADate)
            }
        }
        if let raw = root["relevance"] {
            if let number = reader.finite(raw), (0...100).contains(number) { document.relevance = number }
            else { reader.note("relevance", "is not a number between 0 and 100") }
        }
        if let trees = root["families"] {
            document.regions = regions(trees, reader)
        }
        guard update || document.drawsSomething else {
            return Reading(document: document, state: .unreadable("draws nothing on the lock screen: no tracker, no poll and no families.lockScreen"),
                           notes: reader.notes)
        }
        return Reading(document: document, state: .read, notes: reader.notes)
    }

    static func regions(_ trees: Any, _ reader: WidgetReader) -> [ActivityRegion: WidgetNode] {
        guard let object = trees as? [String: Any] else { reader.note("families", "is not an object"); return [:] }
        var regions: [ActivityRegion: WidgetNode] = [:]
        for key in object.keys.sorted() where ActivityRegion(rawValue: key) == nil {
            reader.note("families.\(key)", "is not a region; the regions are \(ActivityRegion.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        for region in ActivityRegion.allCases {
            guard let raw = object[region.rawValue] else { continue }
            let path = "families.\(region.rawValue)"
            guard let tree = raw as? [String: Any] else { reader.note(path, "is not a node"); continue }
            if let node = reader.region(tree, path) { regions[region] = node }
        }
        return regions
    }
}

/// Where an activity is drawn: the lock screen (and the banner over another app), and the Dynamic
/// Island's four forms. A region without its own tree draws the tracker design, or the mark.
enum ActivityRegion: String, CaseIterable, Sendable {
    case lockScreen, islandExpanded, islandCompactLeading, islandCompactTrailing, islandMinimal
}

/// The regions and the tint the mind gave, as the activity's state carries them: JSON the extension
/// reads again with the same reader, as the watch reads the phone's slots.
struct ActivityLayout: Equatable, Sendable {
    var regions: [ActivityRegion: WidgetNode] = [:]
    var tint: WidgetColour?

    var isEmpty: Bool { regions.isEmpty && tint == nil }

    var json: [String: Any] {
        var object: [String: Any] = ["version": ActivityDocument.version]
        var trees: [String: Any] = [:]
        for (region, node) in regions { trees[region.rawValue] = node.json }
        if !trees.isEmpty { object["families"] = trees }
        if let tint { object["tint"] = tint.json }
        return object
    }

    var text: String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The kept layout read back. It was judged when written, so a note here is a defect, and
    /// what cannot be read is left out rather than drawn.
    static func read(_ text: String) -> ActivityLayout {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let root = parsed as? [String: Any] else {
            return ActivityLayout()
        }
        let reader = WidgetReader(source: .store)
        var layout = ActivityLayout()
        if let tint = root["tint"], let colour = WidgetColour(tint) { layout.tint = colour }
        if let trees = root["families"] { layout.regions = ActivityDocument.regions(trees, reader) }
        return layout
    }
}

/// What the activity's state carries of a tracker: enough to draw the bar, the step in focus and
/// the estimate, and small enough that every tracker the pane's contract admits fits the payload.
struct TrackerCard: Codable, Hashable, Sendable {
    struct Step: Codable, Hashable, Sendable {
        var label: String
        var state: ProgressTracker.Step.State
        var isPast: Bool { state == .done || state == .skipped }
    }

    var title: String
    var steps: [Step]
    var current: Int
    /// The focused step's note.
    var note: String
    var state: ProgressTracker.State
    var eta: Date?
    var updated: Date
    var ended: Date?
    /// The owner's session name.
    var session: String

    init(_ tracker: ProgressTracker) {
        title = tracker.title
        steps = tracker.steps.map { Step(label: $0.label, state: $0.state) }
        current = min(max(tracker.current, 0), max(tracker.steps.count - 1, 0))
        note = tracker.focus.note
        state = tracker.state
        eta = tracker.eta
        updated = tracker.updated
        ended = tracker.ended
        session = tracker.owner.session
    }

    var fraction: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter(\.isPast).count) / Double(steps.count)
    }

    var focus: Step? { steps.indices.contains(current) ? steps[current] : nil }

    /// How many steps are behind the bar, for "3 of 7".
    var past: Int { steps.filter(\.isPast).count }

    /// The card with every label emptied: the states and the focus still draw, within the budget.
    var withoutLabels: TrackerCard {
        var card = self
        card.steps = steps.map { Step(label: "", state: $0.state) }
        return card
    }
}

/// The activity's content state: a tracker's card, a layout, either or both. Encoded by ActivityKit
/// into the payload the budget counts.
struct ActivityState: Codable, Hashable, Sendable {
    var card: TrackerCard?
    /// `ActivityLayout.text`, when the document gave regions or a tint.
    var layout: String?
    /// When the activity is over (`ActivityDocument.until`): carried in the state since an update
    /// may move it, and the attributes cannot change.
    var until: Date?
    var relevance: Double?

    init(card: TrackerCard? = nil, layout: String? = nil, until: Date? = nil, relevance: Double? = nil) {
        self.card = card
        self.layout = layout
        self.until = until
        self.relevance = relevance
    }

    /// The state a document asks for, over `previous` when it is an update: a document that
    /// carries a tracker replaces the card, one that carries regions or a tint replaces the
    /// layout, one that carries `until` or `relevance` replaces it, and what it does not carry
    /// stands.
    init(_ document: ActivityDocument, tracker: ProgressTracker?, over previous: ActivityState? = nil) {
        card = tracker.map(TrackerCard.init) ?? previous?.card
        layout = document.layout.isEmpty ? previous?.layout : document.layout.text
        until = document.until ?? previous?.until
        relevance = document.relevance ?? previous?.relevance
    }
}

#if canImport(ActivityKit)
/// What does not change for an activity's life: the slot the mind named it by, where its tracker
/// is polled from, and when it began.
struct TopoActivityAttributes: ActivityAttributes, Hashable {
    typealias ContentState = ActivityState

    var slot: String
    var poll: URL?
    var started: Date
}
#else
struct TopoActivityAttributes: Codable, Hashable, Sendable {
    var slot: String
    var poll: URL?
    var started: Date
}
#endif

/// The budget ActivityKit holds attributes and state to, judged here before anything is sent.
enum ActivityPayload {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static func bytes(_ attributes: TopoActivityAttributes, _ state: ActivityState) -> Int {
        ((try? encoder.encode(attributes))?.count ?? 0) + ((try? encoder.encode(state))?.count ?? 0)
    }

    /// `state` within the budget beside `attributes`: as given, or with the card's labels dropped
    /// when that is what puts it over (with a note), or nil with a note when nothing fits.
    static func fit(_ state: ActivityState, with attributes: TopoActivityAttributes) -> (state: ActivityState?, note: String?) {
        if bytes(attributes, state) <= ActivityDocument.payloadLimit { return (state, nil) }
        if let card = state.card {
            var trimmed = state
            trimmed.card = card.withoutLabels
            if bytes(attributes, trimmed) <= ActivityDocument.payloadLimit {
                return (trimmed, "the tracker's labels put the activity over the \(ActivityDocument.payloadLimit) bytes the system holds, so its steps are drawn without them")
            }
        }
        return (nil, "is \(bytes(attributes, state)) bytes with the activity's attributes, over the \(ActivityDocument.payloadLimit) the system holds")
    }
}
#endif
