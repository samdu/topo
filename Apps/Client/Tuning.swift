#if os(iOS)
import Observation
import SwiftUI

/// This device's own hand on the look: where Topo sits — the placement, and the pin a drag on him
/// writes — and, in a debug build, a few of Topo's and the transcript's lengths played with from the
/// settings sheet's Tuning section. It is kept in this device's defaults and worn over the look the
/// vault gives, so a pin survives a relaunch and a `look.json` from the vault does not undo it. It
/// is a `look.json` of the same shape, decoded onto that look by `LookDocument` like any other, so
/// every value it carries is read in the range its field is read in and one out of range falls back
/// for that field alone. Reset removes it.
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
    /// Where a drag left him, as fractions of the transcript's frame; nil is the vault's pin.
    private(set) var pin: CGPoint?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        (values, placement, pin) = Self.read(defaults.string(forKey: Self.key))
    }

    /// Nothing is set: the look is the vault's.
    var isEmpty: Bool { values.isEmpty && placement == nil && pin == nil }

    /// The override as a `look.json`: nil when nothing is set.
    var document: String? {
        guard !isEmpty else { return nil }
        var parts: [String: [String: Any]] = [:]
        for (knob, value) in values { parts[knob.part, default: [:]][knob.rawValue] = value }
        if let placement { parts["mascot", default: [:]]["placement"] = placement.rawValue }
        if let pin { parts["mascot", default: [:]]["pin"] = ["x": Double(pin.x), "y": Double(pin.y)] }
        guard let data = try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `look` with the override worn over it, through the document reader, so the ranges and the
    /// per-field fallbacks are the vault's own.
    func worn(over look: Look) -> Look {
        guard let document else { return look }
        return LookDocument.read(document, onto: look).look
    }

    func set(_ knob: Knob, to value: Double) {
        values[knob] = value
        save()
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
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        if let document { defaults.set(document, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    /// What a kept override says, read back as loosely as it was written: anything that is not one
    /// of these is left out here, and anything out of its range is refused where it is worn.
    private static func read(_ document: String?)
        -> (values: [Knob: Double], placement: Look.Mascot.Placement?, pin: CGPoint?) {
        guard let data = document?.data(using: .utf8),
              let parts = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        else { return ([:], nil, nil) }
        var values: [Knob: Double] = [:]
        for knob in Knob.allCases {
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

/// The settings sheet's Tuning section: where Topo sits, with the pin a drag left, and in a debug
/// build a slider for each knob, labelled with the value worn; and a Reset. What it shows is read
/// off the look in the environment, which is the tuned one, so what it says is what is drawn.
struct TuningSection: View {
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
            #if DEBUG
            ForEach(Tuning.Knob.allCases) { knob in
                let value = knob.value(in: look)
                VStack(alignment: .leading) {
                    LabeledContent(knob.title, value: knob.label(value))
                    Slider(value: Binding(get: { value }, set: { tuning.set(knob, to: $0) }), in: knob.range, step: knob.step)
                        .accessibilityIdentifier("tuning-\(knob.rawValue)")
                }
            }
            #endif
            Button("Reset", role: .destructive) { tuning.reset() }
                .disabled(tuning.isEmpty)
        } header: {
            Text("Tuning")
        } footer: {
            Text("Drag Topo to pin him. Worn over the vault's look on this device until reset.")
        }
    }
}

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
