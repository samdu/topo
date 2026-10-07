#if os(iOS)
import SwiftUI

/// The bar under the transcript: a floating pane of glass with the microphone set into the
/// middle of it and its controls at each end — the keyboard and the mute on the leading flank,
/// the model on the trailing one, which opens the model slider across the top of the pane. It
/// holds no state of its own beyond what it is handed, so a canvas can show every state it has.
///
/// The glass is what says the microphone is open. A thumb on the microphone covers the jewel,
/// so the pane takes Topo's colour, the jewel goes pale under the thumb and the glow spills onto
/// the transcript behind: the state reads at the edges, where the hand is not. Every value it
/// draws with is a field of `Look.Composer`, so the pane, the etch, the well and both states of
/// the jewel are reachable from outside the source.
///
/// Words are not written here. The person's next turn is written at the end of the transcript,
/// in the bubble it is about to become (`DraftRow`); this raises the keyboard for it and holds
/// the microphone. While the keyboard is up the pane is shorter: the microphone is drawn at
/// `compactShare` of its size and the flanks at theirs (`ComposerGeometry`).
struct Composer: View {
    /// The keyboard is up, and the row at the end of the transcript has it.
    @Binding var typing: Bool
    /// What the microphone is doing, read off `VoiceInput` by the chat screen.
    var mic: MicState = .init()
    /// How much of a pane the pane is, 0 to 1: the surface, its edge and the glow it spills are
    /// drawn at this, so at 0 there is the well, the jewel and the flanks over whatever is behind
    /// and nothing else. The chat works it out from the transcript's scroll geometry
    /// (`PanePresence`); a screen with no geometry to read hands over 1, which is the pane whole.
    var presence: Double = 1
    /// The keyboard is on screen, as the keyboard's own safe area says (`KeyboardInset`), not
    /// `typing`, which is what was asked for and outlives the field while a turn is on its way.
    /// The pane is drawn short under it. It changes in the transaction the keyboard's rise and
    /// fall is animated in, and nothing here animates it on a curve of its own, so the pane goes
    /// short and tall again on the keyboard's curve and in step with it.
    var keyboard = false
    /// Called with true on the press and false on the release, and the state the microphone was
    /// drawn in when it came: the press is what the person saw. The session logic is
    /// `VoiceInput`'s, and a press on Stop is a stop (`MicPress`); this passes the press on and
    /// nothing else.
    var micPressed: (Bool, MicState) -> Void = { _, _ in }
    /// What the UI test decodes after a press (`VoiceInput.Report` as JSON), read from the
    /// microphone's accessibility value in a debug build only.
    var micReport: String?
    /// Replies to spoken turns are read aloud. The mute on the leading flank says so and asks for
    /// the other; what muting ends is the chat's.
    var readsAloud = true
    var setReadsAloud: (Bool) -> Void = { _ in }
    /// The models the chat offers and the one chosen, or nil where there is no choice to make.
    var models: Models?
    @Environment(\.look) private var look

    /// The model slider as the glass draws it: the stops, smallest model first, the one chosen,
    /// and whether the slider is open. A value the chat makes and two things it is told, so the
    /// glass knows no model by name.
    struct Models {
        struct Stop: Equatable, Identifiable, Sendable {
            /// The model's alias, which is what `choose` is handed.
            var id: String
            /// What the look calls it.
            var name: String
        }

        var stops: [Stop]
        var chosen: String
        var open = false
        var setOpen: (Bool) -> Void = { _ in }
        var choose: (String) -> Void = { _ in }

        /// The stop nearest `x` on a line `width` long whose first and last stops are `inset`
        /// from its ends: where a finger on the line is.
        static func nearest(to x: CGFloat, width: CGFloat, inset: CGFloat, count: Int) -> Int? {
            guard count > 0, x.isFinite, width.isFinite else { return nil }
            guard count > 1 else { return 0 }
            let span = max(width - 2 * inset, 1)
            let share = min(max((x - inset) / span, 0), 1)
            return Int((share * CGFloat(count - 1)).rounded())
        }

        /// How far along the line stop `index` of `count` is, 0 to 1; the middle for a lone stop.
        static func share(of index: Int, count: Int) -> CGFloat {
            count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
        }
    }

    /// The slider is drawn: open, and with no keyboard up, under which the pane is short.
    private var sliderShown: Bool { models?.open ?? false }

    /// What the microphone is doing, and which of the five the glass draws for it. The chat
    /// screen reads four facts off `VoiceInput` and one off `Speaker`, and this decides what they
    /// look like, so the mapping is a value a test can make rather than a branch inside a view.
    struct MicState: Equatable, Sendable {
        /// A press would open the microphone: not denied, and the ear resident.
        var canListen = true
        /// The microphone is open, on whatever surface holds it.
        var listening = false
        /// Which surface that is. The glass lights for this screen's own session and not for
        /// the first run's.
        var owner: VoiceInput.Gate?
        /// Opened by a tap, so it stays open until the next press.
        var handsFree = false
        /// The speaker is reading a reply aloud (`Speaker.speaking`).
        var speaking = false

        /// The five states the glass draws.
        enum Appearance: String, Equatable, Sendable, CaseIterable {
            /// Nothing is open and a press would open something.
            case idle
            /// A thumb is on the microphone: the flanks go, because nothing beside it is
            /// reachable under that hand.
            case held
            /// Opened by a tap and left open, so the hand is off the glass.
            case handsFree
            /// A press would be refused. The diagnostics `speech` row says why.
            case dimmed
            /// Topo is reading a reply aloud: a press stops him and opens nothing.
            case stop
        }

        /// The microphone is open on this screen.
        private var mine: Bool { listening && owner == .chat }
        /// The glass has taken the colour, either way it was opened.
        var open: Bool { appearance == .held || appearance == .handsFree }
        /// The thumb is on the glass, so what it covers is not worth drawing.
        var holding: Bool { appearance == .held }

        /// The owner is asked before the manner of opening: a session this screen does not own
        /// leaves the glass alone however it was opened, so `handsFree` is read only once the
        /// microphone is known to be this screen's.
        ///
        /// A reply being read makes the button Stop unless this screen's microphone is open, and
        /// ahead of a press that would be refused, since stopping needs no microphone. An open one
        /// keeps its state: the next press on it is the one that sends, and it stops the reply too.
        var appearance: Appearance {
            if speaking, !mine { .stop } else if !canListen { .dimmed } else if !mine { .idle }
            else if handsFree { .handsFree } else { .held }
        }

        /// `VoiceInput`'s state in words, or Stop while Topo is speaking: the only route the UI
        /// suites have to this button.
        var label: String {
            appearance == .stop ? "Stop speaking"
                : handsFree ? "Listening; press to send" : listening ? "Listening; release to send" : "Hold to talk"
        }

        /// The mark cut into the stone: the waveform hands free, a stop while Topo is speaking, the
        /// microphone otherwise. A held press reads off the glass, not the mark.
        var glyph: String {
            switch appearance {
            case .handsFree: "waveform"
            case .stop: "stop.fill"
            case .idle, .held, .dimmed: "mic.fill"
            }
        }
    }

    var body: some View {
        let geometry = ComposerGeometry.of(look.composer, keyboard: keyboard)
        VStack(spacing: look.composer.models.spacing) {
            if sliderShown, let models {
                ModelSlider(models: models, ink: ink)
                    .padding(.top, look.composer.models.topInset)
                    .opacity(flankOpacity)
                    .transition(.opacity)
            }
            HStack(spacing: look.composer.spacing) {
                // The two ends take the same width, which is what keeps the microphone in the
                // middle of the glass. A control that has gone keeps its place, so the glass
                // never changes size.
                leading
                    .etched(look.composer.flank, ink: ink)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(flankOpacity)
                micButton(geometry)
                trailing
                    .etched(look.composer.flank, ink: ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(flankOpacity)
            }
            .padding(.horizontal, look.composer.horizontalInset)
        }
        .padding(.vertical, geometry.verticalInset)
        .anchorPreference(key: ComposerFrames.Pane.self, value: .bounds) { $0 }
        // The whole pane is off limits to Topo, at every presence.
        .mascotPane()
        .background(lozenge(geometry).opacity(max(presence, Self.leastSurface)).allowsHitTesting(presence > 0))
        .shadow(look.composer.glow.at(mic.open ? presence : 0))
        .containerRelativeFrame(.horizontal) { width, _ in width * look.composer.widthFraction }
        .padding(.bottom, look.composer.bottomPadding)
        .animation(.easeInOut(duration: look.composer.duration), value: mic.appearance)
        .animation(.easeInOut(duration: look.composer.duration), value: typing)
        .animation(.easeInOut(duration: look.composer.duration), value: sliderShown)
        .animation(.easeInOut(duration: look.composer.presenceDuration), value: presence)
    }

    /// The least the surface is drawn at, which is not nothing: at nothing SwiftUI takes it out of
    /// what is drawn, and a surface put back mid-way through the keyboard's rise is put where the
    /// pane is going rather than where it is, so it would fade in ahead of the pane instead of
    /// riding up with it. Under half a step of an 8-bit alpha, so nothing of it is seen, and it
    /// takes no touch while the presence is nothing, as a surface that is not drawn takes none.
    static let leastSurface = 0.001

    /// How much of the two ends is drawn: all of it, except under a thumb on the microphone.
    private var flankOpacity: Double { mic.holding ? look.composer.flank.heldOpacity : 1 }

    /// The ink both ends are etched in: Topo's colour on clear glass, white once the glass
    /// itself has taken that colour.
    private var ink: Color { mic.open ? look.composer.flank.openInk : look.composer.flank.ink }

    /// The model: the control that opens the slider across the top of the pane and shuts it
    /// again, which says the model chosen as its value. Nothing where there is no choice to make;
    /// the flank keeps its space either way, so the microphone stays in the middle.
    @ViewBuilder private var trailing: some View {
        if let models {
            let flank = look.composer.flank
            HStack(spacing: 0) {
                Button { models.setOpen(!models.open) } label: {
                    Self.mark(flank.models, flank.modelsOpen, second: sliderShown).font(flank.font)
                }
                .accessibilityIdentifier("composer-model")
                .accessibilityLabel(sliderShown ? "Close the model slider" : "Choose the model")
                .accessibilityValue(models.stops.first { $0.id == models.chosen }?.name ?? "")
                .frame(maxWidth: .infinity)
                // The far half is nobody's, which is what mirrors the keyboard's across the well.
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// The way to the keyboard, and back from it, and beside it the mute. The keyboard's is one
    /// control with two states rather than two controls, since the row it raises the keyboard for
    /// is the only thing it has to undo; the mute is the same, replies read aloud or not.
    private var leading: some View {
        let flank = look.composer.flank
        return HStack(spacing: 0) {
            Button { typing.toggle() } label: {
                Self.mark(flank.keyboard, flank.keyboardDown, second: typing).font(flank.font)
            }
            .accessibilityLabel(typing ? "Hide the keyboard" : "Type instead")
            .frame(maxWidth: .infinity)
            Button { setReadsAloud(!readsAloud) } label: {
                Self.mark(flank.speaking, flank.muted, second: !readsAloud).font(flank.font)
            }
            .accessibilityIdentifier("composer-mute")
            .accessibilityLabel(readsAloud ? "Mute replies" : "Read replies aloud")
            .frame(maxWidth: .infinity)
        }
    }

    /// A control with two states: both marks are laid out and one is drawn, so the control is the
    /// size of the larger of them either way. The keyboard's second mark is taller than its first,
    /// and a flank that grew as the keyboard rose would hold up a pane that is meant to go short.
    private static func mark(_ first: String, _ other: String, second: Bool) -> some View {
        ZStack {
            Image(systemName: first).opacity(second ? 0 : 1)
            Image(systemName: other).opacity(second ? 1 : 0)
        }
    }

    /// The system's glass where there is any, a material of the same shape below it. The tint
    /// is the same value at nothing while the microphone is shut, so what happens when it opens
    /// is an animation of one value and not a swap of one view for another.
    ///
    /// Its corners are the geometry's: the short pane is the resting one scaled, so its radius is
    /// the resting radius at the same share as the well.
    ///
    /// It is drawn at the presence, which is one value again rather than a branch: the whole
    /// surface goes, its edge with it, where there is nothing behind the pane to lens. It is a
    /// background and the glow is a shadow, so neither moves anything and what the pane is drawn
    /// at cannot change where its own edge is measured to be.
    @ViewBuilder private func lozenge(_ geometry: ComposerGeometry) -> some View {
        let shape = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
        let tint = look.composer.tint.opacity(mic.open ? look.composer.tintOpacity : 0)
        switch look.composer.surface {
        case .glass:
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular.tint(tint), in: shape)
            } else {
                shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
            }
        case .material:
            shape.fill(.regularMaterial).overlay(shape.fill(tint))
        case .flat:
            shape.fill(tint)
        }
    }

    /// The stone under the thumb: the open slab while the microphone is open, the resting one
    /// otherwise. The floor of the mark's cut is the same stone, so it is read once here.
    private var jewel: Look.Jewel { mic.open ? look.composer.openJewel : look.jewel }

    /// A slab of agate set into a well cut through the pane, with the microphone cut into it.
    /// Open, the stone goes pale under a milky veil while the glass around it takes the colour,
    /// so a thumb over it still leaves the state readable at its edges.
    ///
    /// The gesture is the chat's: press and release, with the session logic on the far side of
    /// `micPressed`. It sits on the whole well rather than on the mark, so the thumb has the
    /// bore to land in — at whatever size the well is drawn, since the gesture is on the well as
    /// drawn and not as it rests.
    ///
    /// It is drawn at its resting size and scaled to the geometry's share as one piece, so the
    /// well, the jewel and the cut of the mark go short together and animate as one value.
    private func micButton(_ geometry: ComposerGeometry) -> some View {
        Well(well: look.composer.well)
            .overlay {
                StainedGlass(glass: jewel, diameter: geometry.restingJewel)
                    .saturation(mic.appearance == .dimmed ? look.composer.dimmedSaturation : 1)
                    .opacity(mic.appearance == .dimmed ? look.composer.dimmedOpacity : 1)
            }
            .overlay {
                // The symbol is a mask and not ink: what is drawn is the stone under it and the
                // two walls of the cut, from `Look.press`.
                Image(systemName: mic.glyph)
                    .font(.system(size: look.composer.glyph.size, weight: look.composer.glyph.weight))
                    .pressed(look.press, into: jewel, diameter: geometry.restingJewel,
                             cast: mic.open ? look.composer.glyph.openCast : .clear)
            }
            .frame(width: look.composer.well.size, height: look.composer.well.size)
            .scaleEffect(geometry.scale)
            .frame(width: geometry.well, height: geometry.well)
            .contentShape(Circle())
            .anchorPreference(key: ComposerFrames.Well.self, value: .bounds) { $0 }
            // Topo is never drawn over it.
            .mascotWell()
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                micPressed(down, mic)
            }
            // The UI suites look this button up by its label, which is `VoiceInput`'s state in
            // words, or Stop while Topo is speaking.
            .accessibilityLabel(mic.label)
            #if DEBUG
            // What the UI test decodes after a press: the counters, the branch it took, and what
            // the microphone delivered, as JSON (`VoiceInput.Report`). A debug build only, so
            // VoiceOver on a release build hears the label alone.
            .accessibilityValue(micReport ?? "")
            #endif
            // The well keeps its resting width in the row at every share, so the flanks stay
            // where they are and the pane, whose width a wide look's content can set, never
            // narrows under the keyboard.
            .frame(width: geometry.slot)
    }
}

/// The model slider: a line across the top of the pane with a stop for each model, smallest
/// first, each model's name under its stop and a knob on the one chosen. A tap on a stop or its
/// name chooses it, and so does a finger drawn along the line, at the stop it is nearest. The
/// chosen stop reports where it is, which is where Topo sits (`mascotStop`).
private struct ModelSlider: View {
    let models: Composer.Models
    let ink: Color
    @Environment(\.look) private var look

    var body: some View {
        let slider = look.composer.models
        let count = models.stops.count
        let chosen = models.stops.firstIndex { $0.id == models.chosen }
        GeometryReader { proxy in
            // The look's inset, and no more than leaves the stops half the pane to stand along.
            let inset = min(slider.inset, proxy.size.width / 4)
            let span = max(proxy.size.width - 2 * inset, 0)
            let x = { (index: Int) in inset + span * Composer.Models.share(of: index, count: count) }
            let line = slider.knob / 2
            // A stop's column: as wide as the room between two stops, no wider than leaves an end
            // stop's inside the pane, and never too narrow to press.
            let column = max(min(count > 1 ? span / CGFloat(count - 1) : proxy.size.width, 2 * inset), slider.knob)
            ZStack(alignment: .topLeading) {
                Capsule().fill(ink.opacity(slider.restOpacity))
                    .frame(width: span, height: slider.track)
                    .offset(x: inset, y: line - slider.track / 2)
                ForEach(Array(models.stops.enumerated()), id: \.element.id) { index, stop in
                    let own = index == chosen
                    Button { models.choose(stop.id) } label: {
                        VStack(spacing: slider.labelSpacing) {
                            // The knob stands on the chosen stop, so its own mark is not drawn.
                            Circle().fill(own ? Color.clear : ink.opacity(slider.restOpacity))
                                .frame(width: slider.stop, height: slider.stop)
                                .frame(height: slider.knob)
                            Text(stop.name).font(slider.labelFont).lineLimit(1)
                                .foregroundStyle(own ? ink : ink.opacity(slider.restLabelOpacity))
                        }
                        .frame(width: column, height: proxy.size.height, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composer-model-\(stop.id)")
                    .accessibilityLabel(stop.name)
                    .accessibilityAddTraits(own ? .isSelected : [])
                    .mascotStop(own)
                    .position(x: x(index), y: proxy.size.height / 2)
                }
                if let chosen {
                    Circle().fill(ink)
                        .frame(width: slider.knob, height: slider.knob)
                        .position(x: x(chosen), y: line)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: look.composer.duration), value: chosen)
                }
            }
            .contentShape(Rectangle())
            // A finger drawn along the line chooses the stop it is nearest; a tap is the stop's own.
            .simultaneousGesture(DragGesture(minimumDistance: slider.knob / 2).onChanged { drag in
                guard let index = Composer.Models.nearest(to: drag.location.x, width: proxy.size.width,
                                                          inset: inset, count: count),
                      index != chosen else { return }
                models.choose(models.stops[index].id)
            })
        }
        .frame(height: slider.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-models")
    }
}

/// Where the pane and the well are, as laid out, for whatever is drawn over the composer to read:
/// the pane's own bounds, the edge of the glass, and the well's, which is the area a press lands
/// in. `ComposerGeometryTests` holds the one inside the other at every end of the look's ranges.
enum ComposerFrames {
    struct Pane: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }

    struct Well: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }
}

/// How big the microphone is drawn, and the room above and below it, at rest and under the
/// keyboard. A pure function of the look, so what the pane does under the keyboard is arithmetic
/// a test holds at every end of the document's ranges rather than a screen it has to photograph.
///
/// Under the keyboard the well, the jewel and the mark are drawn at `compactShare` of their
/// resting size, and the vertical inset and the pane's corner radius with them, so the pane is that
/// share of its resting height wherever the well is what sets it. The flanks keep their size: a pane whose flanks are taller
/// than its short well is as short as they let it be. The well keeps its resting width in the row
/// (`slot`), so the flanks do not move and neither does the pane's width, even on a look whose
/// content is wider than its share of the screen. The well is never drawn under
/// `Look.Composer.Well.pressable` for the keyboard — one a look makes smaller than that at rest
/// stays at its own size — so the share the whole microphone is drawn at is the larger of the two.
struct ComposerGeometry: Equatable, Sendable {
    /// The share of its resting size the microphone is drawn at: 1 at rest.
    var scale: CGFloat
    /// The well as drawn, which is the area the press lands in.
    var well: CGFloat
    /// The jewel before it is scaled: its own size, and no bigger than the well it is set into.
    var restingJewel: CGFloat
    /// The room above and below the row, as drawn.
    var verticalInset: CGFloat
    /// The width the well takes in the row: its resting size at every share, so the flanks and
    /// the pane's width do not move under the keyboard.
    var slot: CGFloat
    /// The pane's corner radius as drawn: the resting radius at the same share as the well, since
    /// the short pane is the resting one scaled.
    var cornerRadius: CGFloat

    /// The jewel as drawn.
    var jewel: CGFloat { restingJewel * scale }

    static func of(_ composer: Look.Composer, keyboard: Bool) -> ComposerGeometry {
        let resting = composer.well.size
        let jewel = min(composer.well.jewelSize, resting)
        guard keyboard, resting > 0 else {
            return ComposerGeometry(scale: 1, well: resting, restingJewel: jewel, verticalInset: composer.verticalInset,
                                    slot: resting, cornerRadius: composer.cornerRadius)
        }
        let short = max(resting * min(max(composer.compactShare, 0), 1), min(resting, Look.Composer.Well.pressable))
        let scale = short / resting
        return ComposerGeometry(scale: scale, well: short, restingJewel: jewel,
                                verticalInset: composer.verticalInset * scale, slot: resting,
                                cornerRadius: composer.cornerRadius * scale)
    }
}

/// Whether the keyboard is on screen, from the bottom of the screen's safe area: the keyboard's
/// region is part of it while the keyboard is up, so the inset is more than the screen's own
/// (`resting`, the same inset with the keyboard's region ignored). A pure function, so the answer
/// is arithmetic a test can hold; the chat reads both insets off the whole screen. No resting
/// inset yet is no keyboard: a launch has not measured it.
enum KeyboardInset {
    static func isUp(bottom: CGFloat, resting: CGFloat?) -> Bool {
        guard let resting, bottom.isFinite, resting.isFinite else { return false }
        return bottom > resting + 0.5
    }
}

/// How much of a pane the pane is, from where the transcript's content ends and where the pane's
/// own top edge is. Both are measured in one space by the chat screen, so the offer card and the
/// keyboard's rise move the pane's top rather than being assumed away.
///
/// Nothing under the pane is no pane at all: glass over a flat background is a lens with an edge
/// and nothing behind it. It becomes one over `rise` points of content running under it, which
/// is a share and not a step, so the surface arrives as the content does.
///
/// An open microphone is 1 whatever the geometry: the tinted pane is what says the microphone is
/// open, and that must not depend on how much has been said. So is the keyboard: the pane goes
/// short under it, and a pane that is not there cannot be seen to.
/// So is a pane Topo sits on (`holdsTopo`: the look's `glass` placement, or the model slider open): a Topo on invisible glass
/// is a Topo floating.
enum PanePresence {
    /// `contentBottom` and `paneTop` are two edges in one space, positive down. A rise of nothing
    /// is the step the share cannot express: a pane, or none, with nothing in between. `keyboard`
    /// is the row's field holding focus, which is the keyboard asked for.
    static func of(contentBottom: CGFloat, paneTop: CGFloat, rise: CGFloat, open: Bool,
                   keyboard: Bool, holdsTopo: Bool = false) -> Double {
        if open || keyboard || holdsTopo { return 1 }
        let under = contentBottom - paneTop
        guard rise > 0 else { return under > 0 ? 1 : 0 }
        return Double(min(max(under / rise, 0), 1))
    }
}

/// The bore the jewel is set into: a round well cut straight down through the glass. Its floor
/// is dark, its wall throws a deep shadow from the lip, and the lip itself is a hard line —
/// dark where the wall faces away from the light, bright where the cut edge catches it.
struct Well: View {
    let well: Look.Composer.Well

    var body: some View {
        Circle()
            .fill(
                well.floor
                    .shadow(.inner(well.bore))
                    .shadow(.inner(well.lip))
                    .shadow(.inner(well.catchLight))
            )
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: well.edgeColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: well.edgeWidth)
            }
    }
}

extension Look.Shadow {
    /// The same shadow at a share of its own alpha, which is how one value animates to nothing
    /// instead of one view being swapped for another.
    func at(_ share: Double) -> Look.Shadow {
        var faded = self
        faded.color = color.opacity(share)
        return faded
    }
}

private extension View {
    /// Etched into the glass: the glyph a shade under its ink with a light catch below its lower
    /// edges and a dark one above, as a cut into the surface would have.
    func etched(_ flank: Look.Composer.Flank, ink: Color) -> some View {
        foregroundStyle(ink.opacity(flank.etchOpacity))
            .shadow(flank.etchLight)
            .shadow(flank.etchShade)
    }
}

#if DEBUG
/// The row as the canvas drives it: send puts the turn in flight, and holding it gives the words
/// back, which is what the chat does with an outbox entry it takes off the line.
@MainActor private func previewDraft(draft: Binding<String>, typing: Binding<Bool>,
                                     sending: Binding<Bool>) -> Draft {
    let give: @MainActor () -> Void = { sending.wrappedValue = false }
    return Draft(text: draft, typing: typing, sending: sending.wrappedValue,
                 send: { sending.wrappedValue = true },
                 edit: sending.wrappedValue ? give : nil)
}

#Preview("Composer") {
    @Previewable @State var draft = ""
    @Previewable @State var typing = false
    @Previewable @State var sending = false
    @Previewable @State var canListen = true
    @Previewable @State var listening = false
    @Previewable @State var handsFree = false

    VStack(spacing: 0) {
        NavigationStack {
            TranscriptView(turns: PreviewTurns.long, draft: previewDraft(draft: $draft,
                                                                          typing: $typing,
                                                                          sending: $sending))
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge() } }
                .safeAreaInset(edge: .bottom) {
                    Composer(typing: $typing,
                             mic: .init(canListen: canListen, listening: listening,
                                        owner: listening ? .chat : nil, handsFree: handsFree),
                             keyboard: typing)
                }
        }
        Divider()
        VStack(alignment: .leading) {
            Toggle("Can listen", isOn: $canListen)
            Toggle("Listening", isOn: $listening)
            Toggle("Hands free", isOn: $handsFree)
            Toggle("Typing", isOn: $typing)
            Toggle("Sending", isOn: $sending)
        }
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
    }
}
#endif
#endif
