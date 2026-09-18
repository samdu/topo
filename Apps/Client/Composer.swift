#if os(iOS)
import SwiftUI

/// The bar under the transcript: a field to type in, the microphone, and send. It holds no
/// state of its own beyond what it is handed, so the canvas can show every state it has.
struct Composer: View {
    /// The glass: its share of the screen's width, the room around the controls, and its
    /// corners. The height follows the well plus the vertical inset.
    enum Size {
        static let widthFraction: CGFloat = 0.8
        static let horizontalInset: CGFloat = 16
        static let verticalInset: CGFloat = 4
        static let cornerRadius: CGFloat = 32
        /// The well the cabochon sits in, and the cabochon itself.
        static let well: CGFloat = 72
        static let cabochon: CGFloat = 64
        /// Between each flank and the well.
        static let spacing: CGFloat = 25
    }

    /// The keyboard is up and the draft is being typed into the transcript's own bubble.
    @Binding var typing: Bool
    /// What the microphone is doing, read off `VoiceInput` by the chat screen.
    var mic: MicState = .init()
    /// Called with true on the press and false on the release.
    var micPressed: (Bool) -> Void = { _ in }
    /// What the UI test decodes after a press (`VoiceInput.Report` as JSON); read by the
    /// accessibility value in a debug build only.
    var micReport: String?

    struct MicState {
        /// A press would open the microphone: not denied, and the ear resident.
        var canListen = true
        /// The microphone is open on this surface.
        var listening = false
        /// Opened by a tap, so it stays open until the next press.
        var handsFree = false

        /// The microphone is open either way; the glass glows for both.
        var open: Bool { listening || handsFree }

        var label: String {
            handsFree ? "Listening; press to send" : listening ? "Listening; release to send" : "Hold to talk"
        }
    }

    /// Held down to talk: the thumb is on the button, so nothing else on the glass is reachable
    /// and the flanking controls go. Hands free is a tap, so they stay.
    private var holding: Bool { mic.listening && !mic.handsFree }
    /// The controls' ink. Teal on clear glass; white once the glass itself is teal, so a live
    /// control does not read as a dimmed one.
    private var ink: Color { mic.open ? .white : Theme.primary }

    var body: some View {
        HStack(spacing: Size.spacing) {
            // The two sides take the same width, which is what keeps the microphone central.
            // A hidden control keeps its place, so the glass never changes size.
            attachMenu
                .etched(ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(holding ? 0 : 1)
            micButton
            trailing
                .etched(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(holding ? 0 : 1)
        }
        .padding(.horizontal, Size.horizontalInset)
        .padding(.vertical, Size.verticalInset)
        .background(lozenge)
        // The glow: a soft teal shadow that spills onto the transcript under the glass.
        .shadow(color: Theme.primary.opacity(mic.open ? 0.7 : 0), radius: 28, y: 4)
        .containerRelativeFrame(.horizontal) { width, _ in width * Size.widthFraction }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: mic.open)
        .animation(.easeInOut(duration: 0.2), value: holding)
    }

    /// The keyboard; send lives beside the draft bubble in the transcript.
    private var trailing: some View {
        Button { typing = true } label: {
            Image(systemName: "keyboard").font(.title2)
        }
        .accessibilityLabel("Type instead")
    }

    /// What can come in besides words. Every item is a placeholder until its path exists.
    private var attachMenu: some View {
        Menu {
            Button { } label: { Label("Clipboard", systemImage: "doc.on.clipboard") }
            Button { } label: { Label("Take Photo", systemImage: "camera") }
            Button { } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { } label: { Label("Share Screen", systemImage: "rectangle.inset.filled.and.person.filled") }
        } label: {
            Image(systemName: "plus").font(.title2.weight(.semibold))
        }
        .accessibilityLabel("Attach")
    }

    /// Liquid glass where the system has it; a material the same shape before iOS 26. While the
    /// microphone is open the colour drains out of the button into the glass: the thumb that
    /// opened it is over the button, so the glass is what shows the state.
    @ViewBuilder private var lozenge: some View {
        let shape = RoundedRectangle(cornerRadius: Size.cornerRadius, style: .continuous)
        let tint = mic.open ? Theme.primary.opacity(0.55) : Theme.primary.opacity(0)
        if #available(iOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint), in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.fill(tint))
        }
    }

    /// A slab of poured glass set in a well cut into the surface. Lit from behind while the
    /// microphone is open, it goes pale and the glass around it takes the colour, so the thumb
    /// over it still sees the state at its edges.
    private var micButton: some View {
        Well()
            .overlay {
                StainedGlass(lit: mic.open, dimmed: !mic.canListen)
                    .frame(width: Size.cabochon, height: Size.cabochon)
            }
            .overlay {
                // The waveform is hands free, not listening: a held press reads off the glass.
                Image(systemName: mic.handsFree ? "waveform" : "mic.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(mic.open ? Theme.primary : .white)
                    .shadow(color: .black.opacity(mic.open ? 0 : 0.25), radius: 1, y: 1)
            }
            .frame(width: Size.well, height: Size.well)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                micPressed(down)
            }
            .accessibilityLabel(mic.label)
            #if DEBUG
            .accessibilityValue(micReport ?? "")
            #endif
    }
}

/// The bore the jewel sits in: a round well cut straight down into the glass. Its floor is
/// dark, its wall throws a deep shadow from the top lip, and the lip itself is a hard line —
/// dark where the wall faces away from the light, bright where the cut edge catches it.
struct Well: View {
    var body: some View {
        Circle()
            .fill(
                Color.black.opacity(0.28)
                    .shadow(.inner(color: .black.opacity(0.7), radius: 7, y: 5))
                    .shadow(.inner(color: .black.opacity(0.4), radius: 1, y: 1))
                    .shadow(.inner(color: .white.opacity(0.18), radius: 2, y: -2))
            )
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.1), .white.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
    }
}

/// A cabochon cut from a slab of poured glass: deep petrol blue with a milky drift of paler teal
/// across it and a darker band on the diagonal, with a jeweller's true-circle edge around the organic interior. Lit from behind while the microphone is open,
/// so the colour goes pale and the light comes through instead.
struct StainedGlass: View {
    var lit = false
    var dimmed = false

    private let deep = Color(red: 0.05, green: 0.24, blue: 0.36)
    private let mid = Color(red: 0.08, green: 0.42, blue: 0.53)
    private let pale = Color(red: 0.55, green: 0.80, blue: 0.84)
    private let milk = Color(red: 0.80, green: 0.92, blue: 0.93)

    var body: some View {
        Circle()
            .fill(
                // The body of the glass: paler where it is thinner, at the lower right.
                RadialGradient(colors: lit ? [milk, pale, mid] : [mid, deep, deep],
                               center: UnitPoint(x: 0.62, y: 0.72), startRadius: 0, endRadius: 46)
                    .shadow(.inner(color: .black.opacity(lit ? 0.2 : 0.45), radius: 5, y: 3))
                    .shadow(.inner(color: .white.opacity(0.3), radius: 2, y: -2))
            )
            // The milky drift, an off-centre swirl of thinner glass.
            .overlay {
                Ellipse()
                    .fill(RadialGradient(colors: [milk.opacity(lit ? 0.9 : 0.55), pale.opacity(0.25), .clear],
                                         center: .center, startRadius: 0, endRadius: 22))
                    .frame(width: 44, height: 30)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 6, y: 8)
                    .blur(radius: 2)
            }
            // The dark band across the diagonal.
            .overlay {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, deep.opacity(lit ? 0.25 : 0.6), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 14, height: 90)
                    .rotationEffect(.degrees(24))
                    .offset(x: 4, y: -4)
                    .blur(radius: 1.5)
            }
            // The sheen off the top of the slab, and its rim.
            .overlay {
                Circle().fill(
                    LinearGradient(colors: [.white.opacity(0.35), .clear, .clear, .black.opacity(0.15)],
                                   startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)))
            }
            // The cut: a jeweller's edge, a true circle with a bright bevel.
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.15), .black.opacity(0.35)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.5)
            }
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.5 : 1)
    }
}

private extension View {
    /// Etched into the glass: the glyph a shade darker than its ink with a light catch below
    /// its lower edges and a dark one above, as a cut in the surface would have.
    func etched(_ ink: Color) -> some View {
        self.foregroundStyle(ink.opacity(0.9))
            .shadow(color: .white.opacity(0.45), radius: 0.5, y: 0.8)
            .shadow(color: .black.opacity(0.35), radius: 0.5, y: -0.6)
    }
}

#if DEBUG
#Preview("Composer") {
    @Previewable @State var draft = ""
    @Previewable @State var typing = false
    @Previewable @State var canListen = true
    @Previewable @State var listening = false
    @Previewable @State var handsFree = false
    @Previewable @State var sending = false
    @Previewable @State var asking = false

    VStack(spacing: 0) {
        NavigationStack {
        TranscriptView(turns: PreviewTurns.long,
                       replay: Replay(canSpeak: true),
                       actions: TurnActions(edit: { draft = $0.text; typing = true }, undo: { _ in }),
                       draft: Draft(text: $draft, active: $typing, sending: sending,
                                    send: { typing = false; sending = true }),
                       origin: PreviewTurns.origin,
                       question: asking ? PreviewTurns.question : nil)
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge() } }
            .safeAreaInset(edge: .bottom) {
                Composer(typing: $typing,
                         mic: .init(canListen: canListen, listening: listening, handsFree: handsFree))
            }
        }
        Divider()
        VStack(alignment: .leading) {
            Toggle("Can listen", isOn: $canListen)
            Toggle("Listening", isOn: $listening)
            Toggle("Hands free", isOn: $handsFree)
            Toggle("Typing", isOn: $typing)
            Toggle("Sending", isOn: $sending)
            Toggle("Question", isOn: $asking)
        }
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
    }
}
#endif
#endif
