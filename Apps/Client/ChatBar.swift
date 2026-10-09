#if os(iOS)
import SwiftUI

/// The chat's controls in its navigation bar: the model, a control that opens the model slider
/// across the middle of the bar and shuts it again, and the mute. They are the bar's and not the
/// glass's, so they are drawn plainly in `Look.Bar` and are there whatever the pane under the
/// transcript is doing, and each is an item of the bar's own, standing apart from the other.
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

    /// Where the slider's stops are along it: what the slider is laid out by, what a finger on
    /// the line is judged by, and what Topo is put under (`MascotPerch.under`), so the three
    /// cannot disagree.
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

        /// Stop `index`'s column in the space `slider` is in, for a slider drawn there.
        func frame(of index: Int, in slider: CGRect, least: CGFloat) -> CGRect {
            let column = column(least: least)
            return CGRect(x: slider.minX + x(of: index) - column / 2, y: slider.minY, width: column, height: slider.height)
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

    /// The model slider: a line with a stop for each model, smallest first, each model's name
    /// under its stop and a knob on the one chosen. A tap on a stop or its name chooses it, and
    /// so does a finger drawn along the line, at the stop it is nearest. It reports where its
    /// chosen stop is on the screen, which is what Topo comes to hang under.
    struct Slider: View {
        /// Smallest first.
        var models: [Model]
        /// The alias of the one chosen.
        var chosen: String
        var choose: (String) -> Void = { _ in }
        /// The chosen stop's column in the global space, as laid out.
        var stop: (CGRect) -> Void = { _ in }
        @Environment(\.look) private var look
        /// How tall a name's one line is in the look's font at the text size in use, as laid out.
        @State private var name: CGFloat = 0

        var body: some View {
            let slider = look.bar.slider
            let ink = look.bar.ink
            let at = models.firstIndex { $0.id == chosen }
            GeometryReader { proxy in
                // The knob and the gap under it as the names' line leaves them room, so the line
                // the knob is on and the names are both inside the slider, and an end stop no
                // nearer the end than half the knob, so the knob on it is too.
                let (knob, gap) = Stops.fitted(knob: slider.knob, spacing: slider.labelSpacing, in: proxy.size.height, over: name)
                let stops = Stops(count: models.count, width: proxy.size.width, inset: max(slider.inset, knob / 2))
                let line = knob / 2
                let column = stops.column(least: knob)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(ink.opacity(slider.restOpacity))
                        .frame(width: stops.span, height: slider.track)
                        .offset(x: stops.inset, y: line - slider.track / 2)
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        let own = index == at
                        Button { choose(model.id) } label: {
                            VStack(spacing: gap) {
                                // The knob stands on the chosen stop, so its own mark is not drawn.
                                Circle().fill(own ? Color.clear : ink.opacity(slider.restOpacity))
                                    .frame(width: min(slider.stop, knob), height: min(slider.stop, knob))
                                    .frame(height: knob)
                                Text(model.name).font(slider.labelFont).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(own ? ink : ink.opacity(slider.restLabelOpacity))
                            }
                            .frame(width: column, height: proxy.size.height, alignment: .top)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(ChatBar.stop(model.id))
                        .accessibilityLabel(model.name)
                        .accessibilityAddTraits(own ? .isSelected : [])
                        .position(x: stops.x(of: index), y: proxy.size.height / 2)
                    }
                    if let at {
                        Circle().fill(ink)
                            .frame(width: knob, height: knob)
                            .position(x: stops.x(of: at), y: line)
                            .allowsHitTesting(false)
                            .animation(.easeInOut(duration: look.composer.duration), value: at)
                    }
                }
                .contentShape(Rectangle())
                // A name's line, measured and not drawn.
                .background {
                    Text(models.first?.name ?? "").font(slider.labelFont).lineLimit(1).fixedSize().hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { name = $0 }
                }
                // A finger drawn along the line chooses the stop it is nearest; a tap is the stop's own.
                .highPriorityGesture(DragGesture(minimumDistance: knob / 2).onChanged { drag in
                    guard let index = stops.nearest(to: drag.location.x), index != at else { return }
                    choose(models[index].id)
                })
                // To the eighth of a point, so a layout pass that moves nothing reports nothing new.
                .onChange(of: at.map { stops.frame(of: $0, in: proxy.frame(in: .global), least: knob).eighths }, initial: true) { _, frame in
                    if let frame { stop(frame) }
                }
            }
            // The look's width where the bar asks what it would take, which the bar does first,
            // and as narrow as the bar then leaves it: nothing of it is drawn outside its own
            // frame, whatever the look asks of what is inside.
            .frame(minWidth: 0, idealWidth: slider.width, maxWidth: slider.width)
            .frame(height: slider.height)
            .clipped()
            .dynamicTypeSize(...ChatNotices.largestType)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ChatBar.models)
        }
    }
}

private extension CGRect {
    /// This frame with each of its numbers at the nearest eighth of a point.
    var eighths: CGRect {
        let near = { (value: CGFloat) in (value * 8).rounded() / 8 }
        return CGRect(x: near(minX), y: near(minY), width: near(width), height: near(height))
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
