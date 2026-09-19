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
/// the microphone.
struct Composer: View {
    /// The keyboard is up, and the row at the end of the transcript has it.
    @Binding var typing: Bool
    /// What the microphone is doing, read off `VoiceInput` by the chat screen.
    var mic: MicState = .init()
    /// Called with true on the press and false on the release. The session logic is
    /// `VoiceInput`'s; this passes the press on and nothing else.
    var micPressed: (Bool) -> Void = { _ in }
    /// What the UI test decodes after a press (`VoiceInput.Report` as JSON), read from the
    /// microphone's accessibility value in a debug build only.
    var micReport: String?
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
        HStack(spacing: look.composer.spacing) {
            // The two ends take the same width, which is what keeps the microphone in the
            // middle of the glass. A control that has gone keeps its place, so the glass
            // never changes size.
            leading
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(mic.holding ? look.composer.flank.heldOpacity : 1)
            micButton
            trailing
                .etched(look.composer.flank, ink: ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(mic.holding ? look.composer.flank.heldOpacity : 1)
        }
        .padding(.horizontal, look.composer.horizontalInset)
        .padding(.vertical, look.composer.verticalInset)
        .background(lozenge)
        .shadow(look.composer.glow.at(mic.open ? 1 : 0))
        .containerRelativeFrame(.horizontal) { width, _ in width * look.composer.widthFraction }
        .padding(.bottom, look.composer.bottomPadding)
        .animation(.easeInOut(duration: look.composer.duration), value: mic.appearance)
        .animation(.easeInOut(duration: look.composer.duration), value: typing)
    }

    /// The ink both ends are etched in: Topo's colour on clear glass, white once the glass
    /// itself has taken that colour.
    private var ink: Color { mic.open ? look.composer.flank.openInk : look.composer.flank.ink }

    /// Nothing yet: what else can come in besides words has no path into the log, and a control
    /// that does nothing is worse in the person's reach than no control. It keeps the space so
    /// the microphone stays in the middle.
    private var leading: some View {
        Color.clear.frame(width: 0, height: 0)
    }

    /// The way to the keyboard, and back from it. One control with two states rather than two
    /// controls, since the row it raises the keyboard for is the only thing it has to undo.
    private var trailing: some View {
        Button { typing.toggle() } label: {
            Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                .font(look.composer.flank.font)
        }
        .accessibilityLabel(typing ? "Hide the keyboard" : "Type instead")
    }

    /// The system's glass where there is any, a material of the same shape below it. The tint
    /// is the same value at nothing while the microphone is shut, so what happens when it opens
    /// is an animation of one value and not a swap of one view for another.
    @ViewBuilder private var lozenge: some View {
        let shape = RoundedRectangle(cornerRadius: look.composer.cornerRadius, style: .continuous)
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

    /// A slab of poured glass set into a well cut through the pane. Open, it is lit from behind
    /// and goes pale while the glass around it takes the colour, so a thumb over it still leaves
    /// the state readable at its edges.
    ///
    /// The gesture is the chat's: press and release, with the session logic on the far side of
    /// `micPressed`. It sits on the whole well rather than on the mark, so the thumb has the
    /// bore to land in.
    private var micButton: some View {
        Well(well: look.composer.well)
            .overlay {
                StainedGlass(glass: mic.open ? look.composer.openJewel : look.jewel)
                    .frame(width: look.composer.well.jewelSize, height: look.composer.well.jewelSize)
                    .saturation(mic.appearance == .dimmed ? look.composer.dimmedSaturation : 1)
                    .opacity(mic.appearance == .dimmed ? look.composer.dimmedOpacity : 1)
            }
            .overlay {
                // The waveform is hands free, not listening: a held press reads off the glass.
                Image(systemName: mic.appearance == .handsFree ? "waveform" : "mic.fill")
                    .font(.system(size: look.composer.glyph.size, weight: look.composer.glyph.weight))
                    .foregroundStyle(mic.open ? look.composer.glyph.openInk : look.composer.glyph.ink)
                    .shadow(look.composer.glyph.shadow.at(mic.open ? look.composer.glyph.openShadowOpacity : 1))
            }
            .frame(width: look.composer.well.size, height: look.composer.well.size)
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
                                        owner: listening ? .chat : nil, handsFree: handsFree))
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
