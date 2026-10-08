#if os(iOS)
import SwiftUI

/// The bar under the transcript: a floating pane of glass in one of two forms. At rest the
/// microphone is set into the middle of it, with the control for everything else on the leading
/// flank and the way to the keyboard on the trailing one. With the keyboard up it is one row:
/// the microphone in its leading end, then the control for everything else, the field the next
/// turn is written in, and the send. It holds nothing of its own beyond the field's focus, so a
/// canvas can show every state it has.
///
/// The two forms are one layout over the same views (`ComposerRow`), so the field is one field
/// and the form changing is every view moving to its other place: it changes in the transaction
/// the keyboard's rise and fall is animated in, and nothing here animates it on a curve of its
/// own, so the pane widens and goes short on the keyboard's curve and in step with it.
///
/// The glass is what says the microphone is open. A thumb on the microphone covers the jewel,
/// so the pane takes Topo's colour, the jewel goes pale under the thumb and the glow spills onto
/// the transcript behind: the state reads at the edges, where the hand is not. Every value it
/// draws with is a field of `Look`, so the pane, the etch, the well, both states of the jewel,
/// the field and the send are reachable from outside the source.
struct Composer: View {
    /// The person's next turn: what is written, whether the keyboard is asked for, and whether
    /// the pane is a row (`Draft.row`), which is the keyboard on screen as the keyboard's own
    /// safe area says (`KeyboardInset`) or the field holding focus with no keyboard to come
    /// (`ComposerForm`).
    var draft: Draft
    /// What the microphone is doing, read off `VoiceInput` by the chat screen.
    var mic: MicState = .init()
    /// How much of a pane the pane is, 0 to 1: the surface, its edge and the glow it spills are
    /// drawn at this, so at 0 there is the well, the jewel and the flanks over whatever is behind
    /// and nothing else. The chat works it out from the transcript's scroll geometry
    /// (`PanePresence`); a screen with no geometry to read hands over 1, which is the pane whole.
    var presence: Double = 1
    /// Called with true on the press and false on the release, and the state the microphone was
    /// drawn in when it came: the press is what the person saw. The session logic is
    /// `VoiceInput`'s, and a press on Stop is a stop (`MicPress`); this passes the press on and
    /// nothing else.
    var micPressed: (Bool, MicState) -> Void = { _, _ in }
    /// What the UI test decodes after a press (`VoiceInput.Report` as JSON), read from the
    /// microphone's accessibility value in a debug build only.
    var micReport: String?
    /// Told whether the field holds focus. `Draft.typing` is what was asked for and outlives the
    /// field while a turn is on its way; this is what is, and it is what the glass is present
    /// for.
    var focused: @MainActor (Bool) -> Void = { _ in }
    @Environment(\.look) private var look
    /// The field takes the keyboard while the keyboard is asked for, and lets it go with it.
    @FocusState private var writing: Bool

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
            /// A thumb is on the microphone: what is beside it goes, because nothing there is
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
        let row = draft.row
        let geometry = ComposerGeometry.of(look.composer, row: row)
        // The well, the control and the field are the same views in both forms, each placed by
        // what it is: a field that was one of two would be a second field, and the keyboard would
        // fall between them. The send is the row's and the way to the keyboard the resting
        // pane's, and each is there only in its own form, so neither is pressed or read in the
        // other.
        ComposerRow(row: row, composer: look.composer, draft: look.draft, geometry: geometry) {
            micButton(geometry).layoutValue(key: ComposerPart.self, value: .well)
            more.layoutValue(key: ComposerPart.self, value: .more)
            field(shown: row).layoutValue(key: ComposerPart.self, value: .field)
            line.layoutValue(key: ComposerPart.self, value: .line)
            if row {
                send.layoutValue(key: ComposerPart.self, value: .send)
            } else {
                keyboard.layoutValue(key: ComposerPart.self, value: .keyboard)
            }
        }
        .anchorPreference(key: ComposerFrames.Pane.self, value: .bounds) { $0 }
        // The whole pane is off limits to Topo, at every presence.
        .mascotPane()
        .background(lozenge(geometry).opacity(max(presence, Self.leastSurface)).allowsHitTesting(presence > 0))
        .shadow(look.composer.glow.at(mic.open ? presence : 0))
        .containerRelativeFrame(.horizontal) { width, _ in
            ComposerGeometry.width(look.composer, column: look.transcript.maximumLineWidth, in: width, row: row)
        }
        .padding(.bottom, look.composer.bottomPadding)
        .animation(.easeInOut(duration: look.composer.duration), value: mic.appearance)
        .animation(.easeInOut(duration: look.composer.presenceDuration), value: presence)
        .onAppear { writing = draft.typing }
        .onChange(of: draft.typing) { _, wanted in writing = wanted }
        // A turn on its way closes the field, which takes the keyboard with it. The keyboard is
        // the person's until they put it down, so it comes back the moment the turn lands and
        // there is somewhere to type again.
        .onChange(of: draft.state) { _, now in if now != .inFlight, draft.typing { writing = true } }
        // The keyboard lowered from anywhere — a drag down the transcript, another screen — is
        // the field saying so, which is what keeps the control that raised it honest. The field
        // closing to a turn on its way is not that, and says nothing about what the person
        // wants next.
        .onChange(of: writing) { _, held in
            focused(held)
            guard draft.state != .inFlight else { return }
            draft.typing = held
        }
        .onDisappear { focused(false) }
    }

    /// The least the surface is drawn at, which is not nothing: at nothing SwiftUI takes it out of
    /// what is drawn, and a surface put back mid-way through the keyboard's rise is put where the
    /// pane is going rather than where it is, so it would fade in ahead of the pane instead of
    /// riding up with it. Under half a step of an 8-bit alpha, so nothing of it is seen, and it
    /// takes no touch while the presence is nothing, as a surface that is not drawn takes none.
    static let leastSurface = 0.001

    /// How much of what is beside the microphone is drawn: all of it, except under a thumb on the
    /// microphone. It keeps its place either way, so the glass never changes size.
    private var besideOpacity: Double { mic.holding ? look.composer.flank.heldOpacity : 1 }

    /// The ink the controls are etched in: Topo's colour on clear glass, white once the glass
    /// itself has taken that colour.
    private var ink: Color { mic.open ? look.composer.flank.openInk : look.composer.flank.ink }

    /// The control for everything else, which opens nothing yet: in both forms, beside the well.
    private var more: some View {
        Button {} label: {
            Image(systemName: look.composer.flank.more).font(look.composer.flank.font)
        }
        .accessibilityIdentifier("composer-more")
        .accessibilityLabel("More")
        .etched(look.composer.flank, ink: ink)
        .opacity(besideOpacity)
    }

    /// The way to the keyboard, on the resting pane. The way back from it is a drag down the
    /// transcript or a tap on its empty space, so the row has no place for this and it is not
    /// there.
    private var keyboard: some View {
        Button { draft.typing = true } label: {
            Image(systemName: look.composer.flank.keyboard).font(look.composer.flank.font)
        }
        .accessibilityLabel("Type instead")
        .etched(look.composer.flank, ink: ink)
        .opacity(besideOpacity)
    }

    /// What is written, as the field holds it: nothing while the row at the end of the transcript
    /// is what draws the words — a turn on its way, a caption with the keyboard down — so they
    /// are drawn once and read once, and a field that draws nothing writes nothing back.
    private var written: Binding<String> {
        Binding(get: { draft.drawer == .row ? "" : draft.text },
                set: { if draft.drawer != .row { draft.text = $0 } })
    }

    /// The field the next turn is written in, in the draft's own enclosure and the transcript's
    /// own type: one line, growing a line at a time to `maximumLines` and scrolling inside itself
    /// past that. It is the row's alone: at rest it is not drawn or pressed, and it stays where it
    /// is so the keyboard has one field to rise for. The system's text view stays in the
    /// accessibility tree in both forms; activating it there is a way to the keyboard.
    private func field(shown: Bool) -> some View {
        let enclosure = look.draft.written
        return TextField("", text: written, axis: .vertical)
            .textFieldStyle(.plain)
            .font(look.transcript.bodyFont)
            .foregroundStyle(look.transcript.text)
            .lineLimit(1...look.draft.maximumLines)
            .focused($writing)
            .disabled(draft.state == .inFlight)
            .onSubmit(draft.send)
            .accessibilityLabel("What to say")
            .padding(.horizontal, enclosure.horizontalPadding)
            .padding(.vertical, enclosure.verticalPadding)
            .background { TurnShape.fill(enclosure).opacity(besideOpacity) }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }

    /// One line of the field, which is not drawn: the height the row is laid out round, so a
    /// field of one line stands level with the well and one of more grows upward from there.
    private var line: some View {
        Text(" ")
            .font(look.transcript.bodyFont)
            .padding(.vertical, look.draft.written.verticalPadding)
            .hidden()
            .accessibilityHidden(true)
    }

    /// Sends what is written, as a typed turn. With nothing but space written it says so rather
    /// than being pressed and doing nothing.
    private var send: some View {
        let nothing = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: draft.send) {
            Image(systemName: look.draft.sendSymbol)
                .font(look.draft.sendFont)
                .foregroundStyle(look.draft.sendInk)
                .opacity(nothing ? look.draft.sendRestingOpacity : 1)
                .frame(width: look.draft.slot, height: look.draft.slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(nothing)
        .accessibilityLabel("Send")
        .opacity(besideOpacity)
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
    }
}

/// What each view of the pane is, which is what `ComposerRow` places it by.
enum ComposerPart: LayoutValueKey {
    case well, more, field, line, send, keyboard
    static let defaultValue: ComposerPart? = nil
}

/// The pane's two forms as one layout: the same views, each put where `ComposerPlan` says it
/// stands in the form asked for. The pane is as wide as it is offered and as tall as the plan
/// makes it, which in the row is as tall as what is written.
struct ComposerRow: Layout {
    var row: Bool
    var composer: Look.Composer
    var draft: Look.Draft
    var geometry: ComposerGeometry

    private func part(_ part: ComposerPart, of subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[ComposerPart.self] == part }
    }

    private func plan(width: CGFloat, _ subviews: Subviews) -> ComposerPlan {
        let size = { (wanted: ComposerPart) in part(wanted, of: subviews)?.sizeThatFits(.unspecified) ?? .zero }
        let marks = max(size(.more).height, row ? size(.send).height : size(.keyboard).height)
        guard row else {
            return .resting(composer, geometry: geometry, width: width, marks: marks, line: size(.line).height)
        }
        return .row(composer, draft: draft, geometry: geometry, width: width, marks: marks,
                    line: size(.line).height) { wide in
            part(.field, of: subviews)?.sizeThatFits(ProposedViewSize(width: wide, height: nil)).height ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Never narrower than what it holds side by side with everything yielded, whatever it is
        // offered: a look whose share of the screen is less than that has a pane wider than its
        // share and not one whose controls stand on each other.
        let floor = ComposerPlan.floor(composer, draft: draft, geometry: geometry, row: row)
        return plan(width: max(proposal.width ?? floor, floor), subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, subviews)
        let at = { (point: CGPoint) in CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y) }
        part(.well, of: subviews)?.place(at: at(plan.well.center), anchor: .center,
                                         proposal: ProposedViewSize(plan.well.size))
        part(.more, of: subviews)?.place(at: at(plan.more), anchor: .center, proposal: .unspecified)
        part(.send, of: subviews)?.place(at: at(plan.send), anchor: .center, proposal: .unspecified)
        part(.keyboard, of: subviews)?.place(at: at(plan.keyboard), anchor: .center, proposal: .unspecified)
        part(.field, of: subviews)?.place(at: at(plan.field.origin), anchor: .topLeading,
                                          proposal: ProposedViewSize(plan.field.size))
        part(.line, of: subviews)?.place(at: at(plan.field.origin), anchor: .topLeading, proposal: .unspecified)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
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

/// How big the microphone is drawn, and the room above and below it, at rest and as a row. A
/// pure function of the look, so what the pane does under the keyboard is arithmetic a test holds
/// at every end of the document's ranges rather than a screen it has to photograph.
///
/// As a row the well, the jewel and the mark are drawn at `compactShare` of their resting size,
/// and the vertical inset and the pane's corner radius with them, so the pane is that share of
/// its resting height wherever the well is what sets it. The controls keep their size: a pane
/// whose controls are taller than its short well is as short as they let it be. The well is
/// never drawn under `Look.Composer.Well.pressable` for the row — one a look makes smaller than
/// that at rest stays at its own size — so the share the whole microphone is drawn at is the
/// larger of the two. Where everything stands is `ComposerPlan`.
struct ComposerGeometry: Equatable, Sendable {
    /// The share of its resting size the microphone is drawn at: 1 at rest.
    var scale: CGFloat
    /// The well as drawn, which is the area the press lands in.
    var well: CGFloat
    /// The jewel before it is scaled: its own size, and no bigger than the well it is set into.
    var restingJewel: CGFloat
    /// The room above and below the row, as drawn.
    var verticalInset: CGFloat
    /// The width the flanks keep clear for the well: its resting size.
    var slot: CGFloat
    /// The pane's corner radius as drawn: the resting radius at the same share as the well, since
    /// the short pane is the resting one scaled.
    var cornerRadius: CGFloat

    /// The jewel as drawn.
    var jewel: CGFloat { restingJewel * scale }

    /// How wide the pane is on a screen `screen` wide: its share of it at rest, and as a row its
    /// own share and no wider than the transcript's column.
    static func width(_ composer: Look.Composer, column: CGFloat, in screen: CGFloat, row: Bool) -> CGFloat {
        guard row else { return screen * composer.widthFraction }
        let share = screen * composer.typingWidthFraction
        return column.isNaN ? share : min(share, max(column, 0))
    }

    static func of(_ composer: Look.Composer, row: Bool) -> ComposerGeometry {
        let resting = composer.well.size
        let jewel = min(composer.well.jewelSize, resting)
        guard row, resting > 0 else {
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

/// Where each view of the pane stands in each of its forms, in the pane's own coordinates. A
/// pure function of the look, the width the pane is given and the sizes of what it holds, so
/// what the two forms are is arithmetic a test holds at every end of the document's ranges
/// rather than a screen it has to photograph.
///
/// At rest the well is in the middle, and the two flanks run from it to the pane's ends: the
/// control for everything else stands in the middle of the leading flank's inner half, and the
/// way to the keyboard mirrors it across the well.
///
/// As a row the well's middle is `jewelInset` from the leading end, the control for everything
/// else `spacing` past the well's edge, and the send `spacing` in from the trailing end; the
/// field has what is between them, `Look.Draft.spacing` clear of each. No control is drawn past
/// the pane's end or over its neighbour for a value the look gives, so each of those is at least
/// half the room the control takes. Where that leaves the field under `Look.Draft.minimumWidth`
/// the look's values yield in order — the spacing, then the jewel's inset, then the room either
/// side of the field — and only a pane narrower than all of that takes the field under its
/// minimum. The row is one line tall where the well lets it be, so a field of one line stands
/// level with the well; what is written past that grows the field and the pane upward, with the
/// well, the control and the send staying on the bottom line.
struct ComposerPlan: Equatable, Sendable {
    var size: CGSize
    /// The well as drawn, which is the area the press lands in.
    var well: CGRect
    /// The middle of the control for everything else.
    var more: CGPoint
    /// The field. At rest, where it is not drawn, it keeps the trailing flank, so it grows out
    /// of the way to the keyboard.
    var field: CGRect
    /// The middle of the send.
    var send: CGPoint
    /// The middle of the way to the keyboard. In the row, where it is not drawn, the field's.
    var keyboard: CGPoint

    static func resting(_ composer: Look.Composer, geometry: ComposerGeometry, width: CGFloat,
                        marks: CGFloat, line: CGFloat) -> ComposerPlan {
        let height = max(geometry.well, marks) + 2 * geometry.verticalInset
        let middle = CGPoint(x: width / 2, y: height / 2)
        // The leading flank, from the pane's inset to the room kept beside the well.
        let inner = max(middle.x - geometry.slot / 2 - composer.spacing, 0)
        let outer = min(max(composer.horizontalInset, 0), inner)
        let flank = inner - outer
        return ComposerPlan(size: CGSize(width: width, height: height),
                            well: CGRect(x: middle.x - geometry.well / 2, y: middle.y - geometry.well / 2,
                                         width: geometry.well, height: geometry.well),
                            more: CGPoint(x: inner - flank / 4, y: middle.y),
                            field: CGRect(x: width - inner, y: middle.y - line / 2, width: flank, height: line),
                            send: CGPoint(x: width - outer - flank / 4, y: middle.y),
                            keyboard: CGPoint(x: width - inner + flank / 4, y: middle.y))
    }

    /// `marks` is the taller of the two controls and `line` the field at one line; `written`
    /// answers how tall the field is at a width, which is how many lines are in it.
    static func row(_ composer: Look.Composer, draft: Look.Draft, geometry: ComposerGeometry, width: CGFloat,
                    marks: CGFloat, line: CGFloat, written: (CGFloat) -> CGFloat) -> ComposerPlan {
        let columns = Columns(composer, draft: draft, geometry: geometry, width: width)
        let band = max(geometry.well, marks, line) + 2 * geometry.verticalInset
        let margin = (band - line) / 2
        let asked = written(columns.field.upperBound - columns.field.lowerBound)
        let tall = max(asked.isFinite ? asked : line, line)
        let height = tall + 2 * margin
        let level = height - band / 2
        let field = CGRect(x: columns.field.lowerBound, y: margin,
                           width: columns.field.upperBound - columns.field.lowerBound, height: tall)
        return ComposerPlan(size: CGSize(width: width, height: height),
                            well: CGRect(x: columns.well - geometry.well / 2, y: level - geometry.well / 2,
                                         width: geometry.well, height: geometry.well),
                            more: CGPoint(x: columns.more, y: level),
                            field: field,
                            send: CGPoint(x: columns.send, y: level),
                            keyboard: CGPoint(x: field.midX, y: level))
    }

    /// The narrowest a pane is laid out: at rest the well's room with the spacing and a control's
    /// room either side of it, and as a row the well, the two controls and the field at its
    /// minimum with everything that yields gone.
    static func floor(_ composer: Look.Composer, draft: Look.Draft, geometry: ComposerGeometry, row: Bool) -> CGFloat {
        guard row else { return geometry.slot + 2 * (max(composer.spacing, 0) + composer.flank.slot) }
        return geometry.well + composer.flank.slot + max(draft.minimumWidth, 0) + draft.slot
    }

    /// The narrowest pane that holds the row with nothing yielded.
    static func least(_ composer: Look.Composer, draft: Look.Draft, geometry: ComposerGeometry) -> CGFloat {
        Columns.taken(composer, draft: draft, geometry: geometry) + max(draft.minimumWidth, 0)
    }

    /// The row across: the middles of the well, the control and the send, and the field's span.
    struct Columns: Equatable, Sendable {
        var well: CGFloat
        var more: CGFloat
        var field: ClosedRange<CGFloat>
        var send: CGFloat

        /// What the row keeps of its width for everything but the field, as the look gives it.
        static func taken(_ composer: Look.Composer, draft: Look.Draft, geometry: ComposerGeometry) -> CGFloat {
            let half = geometry.well / 2
            return max(composer.jewelInset, half) + half
                + max(composer.spacing, composer.flank.slot / 2) + composer.flank.slot / 2
                + max(composer.spacing, draft.slot / 2) + draft.slot / 2
                + 2 * max(draft.spacing, 0)
        }

        init(_ composer: Look.Composer, draft: Look.Draft, geometry: ComposerGeometry, width: CGFloat) {
            let half = geometry.well / 2
            let (control, sending) = (composer.flank.slot / 2, draft.slot / 2)
            var lead = max(composer.jewelInset, half)
            var past = max(composer.spacing, control)
            var trail = max(composer.spacing, sending)
            var gap = max(draft.spacing, 0)
            // What the field is short of its minimum by, taken from each in turn as far as it goes.
            var short = max(draft.minimumWidth, 0)
                - (width - Self.taken(composer, draft: draft, geometry: geometry))
            let give = { (slack: CGFloat) -> CGFloat in
                let given = min(max(short, 0), max(slack, 0))
                short -= given
                return given
            }
            let (first, second) = (past - control, trail - sending)
            let spacing = give(first + second)
            if first + second > 0 {
                past -= spacing * first / (first + second)
                trail -= spacing * second / (first + second)
            }
            lead -= give(lead - half)
            gap -= give(2 * gap) / 2

            well = lead
            more = lead + half + past
            send = width - trail
            let from = more + control + gap
            field = from...max(send - sending - gap, from)
        }
    }
}

/// Which of its two forms the pane is in. The keyboard on screen is the row, and so is the field
/// holding focus with no keyboard: a hardware keyboard, or one floating over the pad, raises
/// nothing the safe area says. A keyboard that is going to rise does so a few frames after the
/// field takes focus, and the pane changes form in the keyboard's own transaction so as to move
/// on its curve, so focus alone is the row only once it has been held `patience` with no
/// keyboard come.
enum ComposerForm {
    /// How long focus is held with no keyboard before the pane takes it that none is coming.
    static let patience: Duration = .milliseconds(250)

    /// `alone` is the field having held focus `patience` with no keyboard on screen.
    static func isRow(keyboard: Bool, focused: Bool, alone: Bool) -> Bool {
        keyboard || (focused && alone)
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
/// open, and that must not depend on how much has been said. So is the keyboard: the pane is a
/// row under it, and a pane that is not there cannot be seen to be.
/// So is a pane Topo sits on (`holdsTopo`: the look's `glass` placement): a Topo on invisible
/// glass is a Topo floating.
enum PanePresence {
    /// `contentBottom` and `paneTop` are two edges in one space, positive down. A rise of nothing
    /// is the step the share cannot express: a pane, or none, with nothing in between. `keyboard`
    /// is the pane's field holding focus, which is the keyboard asked for.
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
/// The draft as the canvas drives it: send puts the turn in flight, and holding it gives the
/// words back, which is what the chat does with an outbox entry it takes off the line.
@MainActor private func previewDraft(draft: Binding<String>, typing: Binding<Bool>,
                                     sending: Binding<Bool>) -> Draft {
    let give: @MainActor () -> Void = { sending.wrappedValue = false }
    return Draft(text: draft, typing: typing, sending: sending.wrappedValue, row: typing.wrappedValue,
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
            let next = previewDraft(draft: $draft, typing: $typing, sending: $sending)
            TranscriptView(turns: PreviewTurns.long, draft: next)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge() } }
                .safeAreaInset(edge: .bottom) {
                    Composer(draft: next,
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
