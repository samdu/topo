#if os(iOS)
import Observation
import SwiftUI

/// This device's own hand on the look: where Topo sits — the placement, and the pin a drag on him
/// writes — in a debug build a few of Topo's and the transcript's lengths played with from the
/// settings sheet's Tuning section, and any field of the look the mind in the guest set through
/// `topo look set` (`LookTool`). It is kept in this device's defaults and worn over the look the
/// vault gives, so a pin survives a relaunch and a `look.json` from the vault does not undo it. It
/// is a `look.json` of the same shape, decoded onto that look by `LookDocument` like any other, so
/// every value it carries is read in the range its field is read in and one out of range falls back
/// for that field alone; a field the mind sets is judged by that same reader before it is kept at
/// all. Reset removes it.
@MainActor
@Observable
final class Tuning {
    static let shared: Tuning = {
        #if DEBUG
        DebugRun.tuning()
        #endif
        return Tuning()
    }()

    /// Where the override is kept: the document itself, as text.
    nonisolated static let key = "topo.tuning"
    /// Where the fields the mind set are kept, apart from the sliders' so a release build can wear
    /// the one and not the other: a `look.json`-shaped document, as text.
    nonisolated static let mindKey = "topo.tuning.mind"

    /// One slider: which field of the look it sets, the range it slides in (the range
    /// `LookDocument` reads that field in), the step, and the unit its value is labelled in.
    enum Knob: String, CaseIterable, Identifiable {
        case clearance, replyTrailingInset, personLeadingInset, scale, roamSpeed

        var id: String { rawValue }

        /// The part of the look the field is in, as the document names it.
        var part: String {
            switch self {
            case .clearance, .scale, .roamSpeed: "mascot"
            case .replyTrailingInset, .personLeadingInset: "transcript"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .clearance: 0...64
            case .replyTrailingInset, .personLeadingInset: 0...200
            case .scale: 0.25...4
            case .roamSpeed: 10...400
            }
        }

        var step: Double { self == .scale ? 0.05 : 1 }

        var title: String {
            switch self {
            case .clearance: "Topo's clearance"
            case .replyTrailingInset: "Reply inset"
            case .personLeadingInset: "Your inset"
            case .scale: "Topo's scale"
            case .roamSpeed: "Topo's speed"
            }
        }

        /// The value with its unit: points, points to an art pixel, points a second.
        func label(_ value: Double) -> String {
            switch self {
            case .scale: String(format: "%.2f pt/px", value)
            case .roamSpeed: String(format: "%.0f pt/s", value)
            default: String(format: "%.0f pt", value)
            }
        }

        /// The field's value in `look`.
        func value(in look: Look) -> Double {
            switch self {
            case .clearance: Double(look.mascot.clearance)
            case .replyTrailingInset: Double(look.transcript.replyTrailingInset)
            case .personLeadingInset: Double(look.transcript.personLeadingInset)
            case .scale: Double(look.mascot.scale)
            case .roamSpeed: Double(look.mascot.roamSpeed)
            }
        }
    }

    private let defaults: UserDefaults
    /// What each slider has been set to; a knob not here is left to the vault's look.
    private(set) var values: [Knob: Double]
    /// Where he sits, as this device set it; nil is the vault's placement.
    private(set) var placement: Look.Mascot.Placement?
    /// Where a drag left him, as fractions of the transcript's frame carried to the
    /// pane's foot; nil is the vault's pin.
    private(set) var pin: CGPoint?
    /// The fields the mind set (`set(_:to:over:)`), as a `look.json`-shaped object: worn in every
    /// build, since it is the mind's own hand on the look and not a developer's slider. A field is
    /// kept here or as a slider's value, never both, so what is worn is the one set last.
    private(set) var mind: [String: Any] = [:]

    /// Whether the sliders' values are worn: in a debug build, which has the sliders. A release
    /// build has only the placement and the pin to show, so it reads only those, and slider values
    /// a debug install left in the defaults are neither worn nor kept.
    #if DEBUG
    static let knobsWorn = true
    #else
    static let knobsWorn = false
    #endif

    init(defaults: UserDefaults = .standard, knobs: Bool = Tuning.knobsWorn) {
        self.defaults = defaults
        (values, placement, pin) = Self.read(defaults.string(forKey: Self.key), knobs: knobs)
        mind = defaults.string(forKey: Self.mindKey).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Nothing is set: the look is the vault's.
    var isEmpty: Bool { values.isEmpty && placement == nil && pin == nil && mind.isEmpty }

    /// The override as a `look.json`: nil when nothing is set.
    var document: String? {
        guard !isEmpty else { return nil }
        return Self.text(slid, deep: mind)
    }

    /// What the sliders, the placement and the pin say, by part.
    private var slid: [String: Any] {
        var parts: [String: [String: Any]] = [:]
        for (knob, value) in values { parts[knob.part, default: [:]][knob.rawValue] = value }
        if let placement { parts["mascot", default: [:]]["placement"] = placement.rawValue }
        if let pin { parts["mascot", default: [:]]["pin"] = ["x": Double(pin.x), "y": Double(pin.y)] }
        return parts
    }

    /// `own` with `other` merged in beneath it, object by object, as JSON text.
    private static func text(_ own: [String: Any], deep other: [String: Any]) -> String? {
        let merged = merge(own, under: other)
        guard !merged.isEmpty, let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every field of `top` and `bottom`, `top`'s where both name one, objects merged all the way down.
    private static func merge(_ top: [String: Any], under bottom: [String: Any]) -> [String: Any] {
        var merged = bottom
        for (key, value) in top {
            if let object = value as? [String: Any], let beneath = merged[key] as? [String: Any] {
                merged[key] = merge(object, under: beneath)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// `look` with the override worn over it, through the document reader, so the ranges and the
    /// per-field fallbacks are the vault's own.
    func worn(over look: Look) -> Look {
        guard let document else { return look }
        return LookDocument.read(document, onto: look).look
    }

    func set(_ knob: Knob, to value: Double) {
        values[knob] = value
        mind = Self.removing([knob.part, knob.rawValue], from: mind)
        save()
    }

    /// The mind sets one field of the look, named by its path in the document (`["transcript",
    /// "replyTrailingInset"]`), to a JSON value. A part (`mascot`) is the fields its object names,
    /// each set as if named alone, so the fields it does not name stay set. Each field is judged
    /// first by the document's own reader, read alone onto `look`: kept only when the reader took it
    /// whole, with no note; otherwise that field is unchanged and the reader's note says why, and
    /// the others still apply. Kept, a field is worn at once and replaces whatever a slider, the
    /// placement or a drag had set for it. A compound field the reader merges onto what it holds
    /// (`LookDocument.merges`: `composer.glow`) is merged into what was set for it before, so
    /// `{"x": 2}` after `{"radius": 9}` keeps the radius; one it replaces whole, a font, is replaced.
    func set(_ path: [String], to value: Any, over look: Look) -> (kept: [String], refused: [String]) {
        let name = path.joined(separator: ".")
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else { return ([], ["\(name) is not a field of the look"]) }
        let named = Self.fields(path, value)
        guard !named.isEmpty else { return ([], ["\(name) sets nothing"]) }
        var kept: [String] = [], refused: [String] = []
        for (field, value) in named {
            let fieldName = field.joined(separator: ".")
            let alone = Self.setting(field, to: value, in: [:])
            guard JSONSerialization.isValidJSONObject(alone),
                  let data = try? JSONSerialization.data(withJSONObject: alone, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                refused.append("\(fieldName) is not a value a look.json can hold")
                continue
            }
            let reading = LookDocument.read(text, onto: look)
            if let note = reading.notes.first { refused.append(note); continue }
            guard case .read(let count) = reading.state, count > 0 else { refused.append("\(fieldName) sets nothing"); continue }
            var merged = value
            if let object = value as? [String: Any], LookDocument.merges(field), let before = stored(field) as? [String: Any] {
                merged = before.merging(object) { $1 }
            }
            mind = Self.setting(field, to: merged, in: mind)
            clearSlid(field)
            kept.append(fieldName)
        }
        if !kept.isEmpty { save() }
        return (kept, refused)
    }

    /// What this device has set at `path`, whoever set it.
    private func stored(_ path: [String]) -> Any? {
        var here: Any? = Self.merge(mind, under: slid)
        for key in path { here = (here as? [String: Any])?[key] }
        return here
    }

    /// What taking back one path came to.
    enum Taken: Equatable {
        case reset
        /// Nothing on this device had set it.
        case unset
        /// Not a field or a part the reader knows, or inside a compound field, which is taken back
        /// whole: nothing changed, and this says why.
        case refused(String)
    }

    /// The mind takes back the fields at `paths`, whoever set them on this device; the vault's look
    /// is worn there again. A path is a whole field or a part, as the document's reader knows
    /// them (`LookDocument.place(of:)`): taking one key out of a compound would leave a value the
    /// reader refuses.
    func reset(_ paths: [[String]]) -> [Taken] {
        let taken = paths.map { path -> Taken in
            let name = path.joined(separator: ".")
            switch LookDocument.place(of: path) {
            case .inside(let field):
                return .refused("\(name) is part of \(field), which is set and taken back whole: reset \(field)")
            case .unknown:
                return .refused("\(name) is not a field of the look")
            case .field, .part:
                let before = document
                mind = Self.removing(path, from: mind)
                clearSlid(path)
                return document == before ? .unset : .reset
            }
        }
        save()
        return taken
    }

    /// Whether the fields at `path` are set on this device, by anyone.
    func sets(_ path: [String]) -> Bool {
        guard let data = document?.data(using: .utf8),
              var here = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        for key in path.dropLast() {
            guard let next = here[key] as? [String: Any] else { return false }
            here = next
        }
        return path.last.map { here[$0] != nil } ?? false
    }

    /// A slider's value, the placement or the pin at `path`, or under it, dropped.
    private func clearSlid(_ path: [String]) {
        for knob in Knob.allCases where [knob.part, knob.rawValue].starts(with: path) { values[knob] = nil }
        if ["mascot", "placement"].starts(with: path) { placement = nil }
        if ["mascot", "pin"].starts(with: path) || path.starts(with: ["mascot", "pin"]) { pin = nil }
    }

    /// `value` at `path` as the fields it sets, by path: a part's object is each of the fields in
    /// it, a part inside it included, and a field, a compound one included, is itself.
    private static func fields(_ path: [String], _ value: Any) -> [(path: [String], value: Any)] {
        guard let object = value as? [String: Any], LookDocument.place(of: path) == .part else { return [(path, value)] }
        return object.flatMap { fields(path + [$0.key], $0.value) }
    }

    private static func setting(_ path: [String], to value: Any, in object: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return object }
        var object = object
        if path.count == 1 {
            object[key] = value
        } else {
            object[key] = setting(Array(path.dropFirst()), to: value, in: object[key] as? [String: Any] ?? [:])
        }
        return object
    }

    private static func removing(_ path: [String], from object: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return object }
        var object = object
        if path.count == 1 {
            object[key] = nil
        } else if let inner = object[key] as? [String: Any] {
            let left = removing(Array(path.dropFirst()), from: inner)
            object[key] = left.isEmpty ? nil : left
        }
        return object
    }

    /// Where he sits, chosen in the settings sheet. The pin is left as it is: choosing `pinned`
    /// puts him back where a drag last left him, or at the look's pin.
    func place(_ placement: Look.Mascot.Placement) {
        self.placement = placement
        save()
    }

    /// A drag on him let go: he is pinned where he was dropped.
    func pin(at point: CGPoint) {
        placement = .pinned
        pin = point
        save()
    }

    /// The override gone: the look is the vault's again.
    func reset() {
        values = [:]
        placement = nil
        pin = nil
        mind = [:]
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.mindKey)
    }

    private func save() {
        if let kept = Self.text(slid, deep: [:]) { defaults.set(kept, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        if let kept = Self.text(mind, deep: [:]) { defaults.set(kept, forKey: Self.mindKey) } else { defaults.removeObject(forKey: Self.mindKey) }
    }

    /// What a kept override says, read back as loosely as it was written: anything that is not one
    /// of these is left out here, and anything out of its range is refused where it is worn.
    private static func read(_ document: String?, knobs: Bool)
        -> (values: [Knob: Double], placement: Look.Mascot.Placement?, pin: CGPoint?) {
        guard let data = document?.data(using: .utf8),
              let parts = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return ([:], nil, nil) }
        var values: [Knob: Double] = [:]
        for knob in Knob.allCases where knobs {
            if let value = parts[knob.part]?[knob.rawValue] as? Double { values[knob] = value }
        }
        let mascot = parts["mascot"] ?? [:]
        let placement = (mascot["placement"] as? String).flatMap(Look.Mascot.Placement.init(rawValue:))
        var pin: CGPoint?
        if let point = mascot["pin"] as? [String: Double], let x = point["x"], let y = point["y"] {
            pin = CGPoint(x: x, y: y)
        }
        return (values, placement, pin)
    }
}

/// The settings sheet's Topo section, its first: where Topo sits, with the pin a drag left, and
/// the Reset for everything this device wears over the vault's look. What it shows is read off
/// the look in the environment, which is the tuned one, so what it says is what is drawn.
struct PlacementSection: View {
    @Environment(\.look) private var look
    var tuning = Tuning.shared

    var body: some View {
        Section {
            Picker("Topo sits", selection: Binding(get: { look.mascot.placement }, set: { tuning.place($0) })) {
                ForEach(Look.Mascot.Placement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("tuning-placement")
            if look.mascot.placement == .pinned {
                LabeledContent("Pinned at", value: String(format: "%.0f%% across, %.0f%% down",
                                                          look.mascot.pin.x * 100, look.mascot.pin.y * 100))
                    .accessibilityIdentifier("tuning-pin")
            }
            Button("Reset", role: .destructive) { tuning.reset() }
                .disabled(tuning.isEmpty)
        } footer: {
            Text("Drag Topo to pin him. Worn over the vault's look on this device until reset.")
        }
    }
}

#if DEBUG
/// The settings sheet's Tuning section, a debug build's alone and its last: a slider for each
/// knob, labelled with the value worn, and the overlay of his field.
struct TuningSection: View {
    @Environment(\.look) private var look
    var tuning = Tuning.shared
    /// The overlay of his field (`MascotFieldOverlay`): this device's, and not the look's.
    @AppStorage(MascotFieldOverlay.key) private var showField = false

    var body: some View {
        Section("Tuning") {
            ForEach(Tuning.Knob.allCases) { knob in
                let value = knob.value(in: look)
                VStack(alignment: .leading) {
                    LabeledContent(knob.title, value: knob.label(value))
                    Slider(value: Binding(get: { value }, set: { tuning.set(knob, to: $0) }), in: knob.range, step: knob.step)
                        .accessibilityIdentifier("tuning-\(knob.rawValue)")
                }
            }
            Toggle("Show his field", isOn: $showField)
                .accessibilityIdentifier("tuning-show-field")
        }
    }
}
#endif

extension Look.Mascot.Placement {
    /// What the settings sheet calls it.
    var title: String {
        switch self {
        case .roam: "Roaming"
        case .glass: "On the glass"
        case .pinned: "Pinned"
        }
    }
}
#endif
