#if os(iOS)
import SwiftUI

/// The bar under the transcript: a floating pane of glass with the microphone set into the
/// middle of it and a control at each end. It holds no state of its own beyond what it is
/// handed, so a canvas can show every state it has.
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
    /// Called with true on the press and false on the release. The session logic is
    /// `VoiceInput`'s; this passes the press on and nothing else.
    var micPressed: (Bool) -> Void = { _ in }
    /// What the UI test decodes after a press (`VoiceInput.Report` as JSON), read from the
    /// microphone's accessibility value in a debug build only.
    var micReport: String?
    /// Topo, in the leading flank: what he stands for, or nil for no Topo at all.
    var mascot: MascotState?
    /// A sheet is over the chat, so he is not seen and is not drawn.
    var covered = false
    @Environment(\.look) private var look

    /// What the microphone is doing, and which of the four the glass draws for it. The chat
    /// screen reads the four facts off `VoiceInput` and this decides what they look like, so
    /// the mapping is a value a test can make rather than a branch inside a view.
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

        /// The four states the glass draws.
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
        var appearance: Appearance {
            if !canListen { .dimmed } else if !mine { .idle } else if handsFree { .handsFree } else { .held }
        }

        /// `VoiceInput`'s state in words, which is the only route the two UI suites have to
        /// this button.
        var label: String {
            handsFree ? "Listening; press to send" : listening ? "Listening; release to send" : "Hold to talk"
        }
    }

    var body: some View {
        let geometry = ComposerGeometry.of(look.composer, keyboard: keyboard)
        HStack(spacing: look.composer.spacing) {
            // The two ends take the same width, which is what keeps the microphone in the
            // middle of the glass. A control that has gone keeps its place, so the glass
            // never changes size.
            leading
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(flankOpacity)
                .anchorPreference(key: LeadingFlank.self, value: .bounds) { $0 }
            micButton(geometry)
            trailing
                .etched(look.composer.flank, ink: ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(flankOpacity)
        }
        // Topo lives in the leading flank. He is laid over the row rather than in it, so he
        // takes no room and moves nothing, and he is placed from the flank as it was measured:
        // the microphone is where it would be without him, and he is clipped short of its well.
        // Under the keyboard he is placed from the short pane at his own size; over an empty
        // transcript, where there is no pane, he floats, and settles in the presence's time.
        .overlayPreferenceValue(LeadingFlank.self) { flank in
            if let mascot, let flank {
                GeometryReader { row in
                    MascotOnGlass(state: mascot, flank: row[flank], row: row.size, share: geometry.scale,
                                  presence: presence, opacity: flankOpacity, covered: covered)
                        .opacity(flankOpacity)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, look.composer.horizontalInset)
        .padding(.vertical, geometry.verticalInset)
        .anchorPreference(key: ComposerFrames.Pane.self, value: .bounds) { $0 }
        .background(lozenge(geometry).opacity(max(presence, Self.leastSurface)).allowsHitTesting(presence > 0))
        .shadow(look.composer.glow.at(mic.open ? presence : 0))
        .containerRelativeFrame(.horizontal) { width, _ in width * look.composer.widthFraction }
        .padding(.bottom, look.composer.bottomPadding)
        .animation(.easeInOut(duration: look.composer.duration), value: mic.appearance)
        .animation(.easeInOut(duration: look.composer.duration), value: typing)
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

    /// No control: what else can come in besides words has no path into the log, and a control
    /// that does nothing is worse in the person's reach than no control. It keeps the space so
    /// the microphone stays in the middle, and Topo is drawn over it.
    private var leading: some View {
        Color.clear.frame(width: 0, height: 0)
    }

    /// The way to the keyboard, and back from it. One control with two states rather than two
    /// controls, since the row it raises the keyboard for is the only thing it has to undo.
    ///
    /// Both marks are laid out and one is drawn, so the control is the size of the larger of them
    /// either way: the keyboard mark is taller than the plain one, and a flank that grew as the
    /// keyboard rose would hold up a pane that is meant to go short.
    private var trailing: some View {
        Button { typing.toggle() } label: {
            ZStack {
                Image(systemName: "keyboard").opacity(typing ? 0 : 1)
                Image(systemName: "keyboard.chevron.compact.down").opacity(typing ? 1 : 0)
            }
            .font(look.composer.flank.font)
        }
        .accessibilityLabel(typing ? "Hide the keyboard" : "Type instead")
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
                // The waveform is hands free, not listening: a held press reads off the glass.
                // The symbol is a mask and not ink: what is drawn is the stone under it and the
                // two walls of the cut, from `Look.press`.
                Image(systemName: mic.appearance == .handsFree ? "waveform" : "mic.fill")
                    .font(.system(size: look.composer.glyph.size, weight: look.composer.glyph.weight))
                    .pressed(look.press, into: jewel, diameter: geometry.restingJewel,
                             cast: mic.open ? look.composer.glyph.openCast : .clear)
            }
            .frame(width: look.composer.well.size, height: look.composer.well.size)
            .scaleEffect(geometry.scale)
            .frame(width: geometry.well, height: geometry.well)
            .contentShape(Circle())
            .anchorPreference(key: ComposerFrames.Well.self, value: .bounds) { $0 }
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                micPressed(down)
            }
            // The two UI suites look this button up by its label, which is `VoiceInput`'s state
            // in words.
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

/// Where the leading flank is, for Topo to be placed from.
private struct LeadingFlank: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
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
enum PanePresence {
    /// `contentBottom` and `paneTop` are two edges in one space, positive down. A rise of nothing
    /// is the step the share cannot express: a pane, or none, with nothing in between. `keyboard`
    /// is the row's field holding focus, which is the keyboard asked for.
    static func of(contentBottom: CGFloat, paneTop: CGFloat, rise: CGFloat, open: Bool,
                   keyboard: Bool) -> Double {
        if open || keyboard { return 1 }
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
