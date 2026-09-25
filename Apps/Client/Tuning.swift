#if DEBUG && os(iOS)
import Observation
import SwiftUI

/// A debug build's own look override, played with from the settings sheet's Tuning section: a
/// few of Topo's and the transcript's lengths, kept in this device's defaults and worn over the
/// look the vault gives. It is a `look.json` of the same shape, decoded onto that look by
/// `LookDocument` like any other, so every value it carries is read in the range its field is read
/// in and one out of range falls back for that field alone. Reset removes it. None of it exists in
/// a release build.
@MainActor
@Observable
final class Tuning {
    static let shared = Tuning()

    /// Where the override is kept: the document itself, as text.
    static let key = "topo.debug.tuning"

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = Self.values(from: defaults.string(forKey: Self.key))
    }

    /// The override as a `look.json`: nil when nothing is set.
    var document: String? {
        guard !values.isEmpty else { return nil }
        var parts: [String: [String: Double]] = [:]
        for (knob, value) in values { parts[knob.part, default: [:]][knob.rawValue] = value }
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

    /// The override gone: the look is the vault's again.
    func reset() {
        values = [:]
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        if let document { defaults.set(document, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    private static func values(from document: String?) -> [Knob: Double] {
        guard let data = document?.data(using: .utf8),
              let parts = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Double]]
        else { return [:] }
        var values: [Knob: Double] = [:]
        for knob in Knob.allCases {
            if let value = parts[knob.part]?[knob.rawValue] { values[knob] = value }
        }
        return values
    }
}

/// The settings sheet's Tuning section: a slider for each knob, labelled with the value worn,
/// and a Reset. The sliders read the look in the environment, which is the tuned one, so what a
/// slider shows is what is drawn.
struct TuningSection: View {
    @Environment(\.look) private var look
    var tuning = Tuning.shared

    var body: some View {
        Section {
            ForEach(Tuning.Knob.allCases) { knob in
                let value = knob.value(in: look)
                VStack(alignment: .leading) {
                    LabeledContent(knob.title, value: knob.label(value))
                    Slider(value: Binding(get: { value }, set: { tuning.set(knob, to: $0) }), in: knob.range, step: knob.step)
                        .accessibilityIdentifier("tuning-\(knob.rawValue)")
                }
            }
            Button("Reset", role: .destructive) { tuning.reset() }
                .disabled(tuning.values.isEmpty)
        } header: {
            Text("Tuning")
        } footer: {
            Text("Debug builds only. Worn over the vault's look on this device until reset.")
        }
    }
}
#endif
