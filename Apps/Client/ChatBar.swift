#if os(iOS)
import SwiftUI

/// The chat's controls in its navigation bar: the mute at its leading edge, and at its trailing
/// one the model, a control that opens the model slider on the pane and shuts it again. They are
/// the bar's and not the glass's, so they are drawn plainly in `Look.Bar` and are there whatever
/// the pane under the transcript is doing.
enum ChatBar {
    /// A model the chat offers: its alias, which is what `choose` is handed, and what the look
    /// calls it.
    struct Model: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
    }

    /// What the UI suites find the controls by: the model's control, the slider it opens, a stop
    /// of the slider by its model's alias, and the mute.
    static let model = "chat-model"
    static let models = "chat-models"
    static func stop(_ alias: String) -> String { "chat-model-\(alias)" }
    static let mute = "chat-mute"

    /// Where the model slider's stops are along it: what the slider is laid out by and what a
    /// finger on the line is judged by, so the two cannot disagree.
    struct Stops: Equatable, Sendable {
        var count: Int
        /// The slider's own width, and from each of its ends to the first and last stop's centre.
        var width: CGFloat
        var inset: CGFloat

        /// The look's inset, and no more than leaves the stops half the slider to stand along.
        init(count: Int, width: CGFloat, inset: CGFloat) {
            self.count = count
            self.width = width.isFinite ? max(width, 0) : 0
            self.inset = min(max(inset.isFinite ? inset : 0, 0), self.width / 4)
        }

        var span: CGFloat { max(width - 2 * inset, 0) }

        /// How far along the line stop `index` is, 0 to 1; the middle for a lone stop.
        func share(of index: Int) -> CGFloat {
            count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
        }

        /// The centre of stop `index`, from the slider's leading edge.
        func x(of index: Int) -> CGFloat { inset + span * share(of: index) }

        /// A stop's column: as wide as the room between two stops, no wider than leaves an end
        /// stop's inside the slider, and never narrower than `least`, which is what is pressed.
        func column(least: CGFloat) -> CGFloat {
            max(min(count > 1 ? span / CGFloat(count - 1) : width, 2 * inset), least)
        }

        /// The stop nearest `x`: where a finger on the line is.
        func nearest(to x: CGFloat) -> Int? {
            guard count > 0, x.isFinite else { return nil }
            guard count > 1 else { return 0 }
            let share = min(max((x - inset) / max(span, 1), 0), 1)
            return Int((share * CGFloat(count - 1)).rounded())
        }

        /// The knob and the gap under it that a slider `height` tall has room for over a name
        /// `name` tall: the name's line is kept whole first, then the knob, then the gap, so no
        /// knob or gap a look asks for puts a model's name out of the slider.
        static func fitted(knob: CGFloat, spacing: CGFloat, in height: CGFloat, over name: CGFloat) -> (knob: CGFloat, spacing: CGFloat) {
            let whole = { (value: CGFloat) in value.isFinite ? max(value, 0) : 0 }
            let room = max(whole(height) - whole(name), 0)
            let knob = min(whole(knob), room)
            return (knob, min(whole(spacing), room - knob))
        }

    }

    /// The model's control: it opens the slider and shuts it again, and says the model chosen as
    /// its value.
    struct ModelButton: View {
        /// What the look calls the model chosen.
        var chosen: String
        var open: Bool
        var setOpen: (Bool) -> Void = { _ in }
        @Environment(\.look) private var look

        var body: some View {
            let flank = look.composer.flank
            Button { setOpen(!open) } label: {
                // Both marks are laid out and one is drawn, so the control is one size either way.
                ZStack {
                    Image(systemName: flank.models).opacity(open ? 0 : 1)
                    Image(systemName: flank.modelsOpen).opacity(open ? 1 : 0)
                }
            }
            .accessibilityIdentifier(ChatBar.model)
            .accessibilityLabel(open ? "Close the model slider" : "Choose the model")
            .accessibilityValue(chosen)
            .barControl(look.bar)
        }
    }

    /// The mute: one control with two marks, which says whether replies to spoken turns are read
    /// aloud and asks for the other; what muting ends is the chat's.
    struct Mute: View {
        var readsAloud = true
        var setReadsAloud: (Bool) -> Void = { _ in }
        @Environment(\.look) private var look

        var body: some View {
            let flank = look.composer.flank
            Button { setReadsAloud(!readsAloud) } label: {
                ZStack {
                    Image(systemName: flank.speaking).opacity(readsAloud ? 1 : 0)
                    Image(systemName: flank.muted).opacity(readsAloud ? 0 : 1)
                }
            }
            .accessibilityIdentifier(ChatBar.mute)
            .accessibilityLabel(readsAloud ? "Mute replies" : "Read replies aloud")
            .barControl(look.bar)
        }
    }
}

private extension View {
    /// One of the bar's own controls, in the bar's font and ink. The bar is a fixed height, so
    /// its controls stop growing with the text setting where its notice does.
    func barControl(_ bar: Look.Bar) -> some View {
        font(bar.font)
            .dynamicTypeSize(...ChatNotices.largestType)
            .tint(bar.ink)
            .foregroundStyle(bar.ink)
    }
}
#endif
