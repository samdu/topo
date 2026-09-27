import SwiftUI
import TopoCore

/// Topo's words drawn as their blocks (`Markdown.blocks`): paragraphs and headings as text, list
/// items behind their markers, rules, fenced code in an enclosure of its own, and whatever sits
/// inside a quote behind a bar for each quote it is inside. Every value is the look's
/// (`Look.Markdown`), and a paragraph is drawn in the transcript's own type and ink, as the
/// transcript draws words.
///
/// `bare` is whether the turn draws nothing round its words. Then what Topo stands clear of is
/// the words themselves: each text reports its own lines (`mascotLines`), and what draws a shape
/// of its own — a code block's enclosure, a quote's bar, a rule — reports its frame
/// (`mascotObstacle`). An enclosed turn reports its enclosure from `TurnRow` and nothing here.
struct MarkdownText: View {
    let source: String
    var bare = true
    /// The turn these words are, which names each code block's place in the transcript
    /// (`CodeBlockCue.Place`) so the transcript can scroll to it. Nil draws the same words with no
    /// place to be scrolled to.
    var reply: TurnRef?
    /// The code block of these words the voice has reached, if any: its enclosure pulses, and it
    /// is what Topo stands beside.
    var cue: CodeBlockCue?
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: look.markdown.blockSpacing) {
            ForEach(Array(Markdown.cached(source).enumerated()), id: \.offset) { _, block in
                quoted(block)
                    .padding(.leading, leadOutside(block))
            }
        }
    }

    /// A block behind a bar for each quote it sits inside, the bars as tall as what they enclose.
    /// The lists outside the quote have led the bars in already; the lists inside it lead only
    /// what the bars enclose, so every bar of one quote stands in one column however deeply what
    /// is inside it is nested.
    @ViewBuilder
    private func quoted(_ block: Markdown.Block) -> some View {
        if block.quote > 0 {
            HStack(alignment: .top, spacing: look.markdown.quoteIndent) {
                ForEach(0..<block.quote, id: \.self) { _ in
                    Rectangle()
                        .fill(look.markdown.quoteBar)
                        .frame(width: look.markdown.quoteBarWidth)
                        .mascotObstacle(bare)
                }
                row(block)
                    .padding(.leading, leadInside(block))
            }
            // The bars are as tall as the words beside them.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            row(block)
        }
    }

    /// How far a block is led in before its bars: by the lists it sits inside that are outside
    /// its outermost quote. A block with no quote has every list outside it, so this is the whole
    /// of its lead and is what it was before there were bars.
    private func leadOutside(_ block: Markdown.Block) -> CGFloat {
        lead(block, lists: block.listsOutside, holdsTheMarker: inside(block) == 0)
    }

    /// How far what the bars enclose is led in: by the lists the block sits inside the quote.
    private func leadInside(_ block: Markdown.Block) -> CGFloat {
        lead(block, lists: inside(block), holdsTheMarker: true)
    }

    /// How many lists the block sits inside its outermost quote.
    private func inside(_ block: Markdown.Block) -> Int { block.depth - block.listsOutside }

    /// `lists` indents, less the one a list item's own marker is drawn for, so the marker sits
    /// where its list starts and anything else inside the item sits one indent in from it. The
    /// innermost list is the one the marker belongs to, so only the side holding it discounts one.
    private func lead(_ block: Markdown.Block, lists: Int, holdsTheMarker: Bool) -> CGFloat {
        var lists = lists
        if case .item = block.kind, holdsTheMarker { lists = max(lists - 1, 0) }
        return CGFloat(lists) * look.markdown.listIndent
    }

    @ViewBuilder
    private func row(_ block: Markdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            words(block.text, font: look.transcript.bodyFont, ink: ink(block))
        case .heading(let level):
            words(block.text, font: look.markdown.headingFont(level), ink: ink(block))
                .accessibilityAddTraits(.isHeader)
        case .item(let marker):
            HStack(alignment: .firstTextBaseline, spacing: look.markdown.markerSpacing) {
                Text(Self.marker(marker))
                    .font(look.transcript.bodyFont)
                    .foregroundStyle(look.markdown.marker)
                    .mascotLines(bare)
                words(block.text, font: look.transcript.bodyFont, ink: ink(block))
            }
        case .code:
            code(String(block.text.characters), number: block.codeNumber)
        case .rule:
            Rectangle()
                .fill(look.markdown.marker)
                .frame(height: look.markdown.ruleWidth)
                .frame(maxWidth: .infinity)
                .mascotObstacle(bare)
        }
    }

    /// A block's words: the transcript's own ink, or a quote's whatever block it is, since words
    /// inside a quote are a quote's words. A fence keeps the look's code ink, being code still.
    private func ink(_ block: Markdown.Block) -> Color {
        block.quote > 0 ? look.markdown.quoteText : look.transcript.text
    }

    /// Words of a block, with inline code in the look's code type and ink and every other
    /// inline style — emphasis, strong, strikethrough — as `Text` draws it.
    private func words(_ text: AttributedString, font: Font, ink: Color) -> some View {
        Text(Self.styled(text, look: look.markdown))
            .font(font)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .mascotLines(bare)
    }

    /// A fenced block in its own enclosure, scrolled sideways or wrapped as the look says, under
    /// its number in the reply at its trailing edge, in the type and ink of a turn's time. The
    /// number is what the voice says in the block's place ("See code block 2."), so a listener
    /// can find the block it means.
    ///
    /// When the voice reaches the block (`cue`), its enclosure pulses (`CodeBlockPulse`) and
    /// reports itself as the frame Topo stands beside (`mascotBeside`).
    private func code(_ text: String, number: Int?) -> some View {
        let reached = number != nil && cue?.number == number ? cue : nil
        return VStack(alignment: .trailing, spacing: look.transcript.captionSpacing) {
            if let number {
                Text("\(number)")
                    .font(look.transcript.labelFont)
                    .foregroundStyle(look.transcript.caption)
                    .mascotLines(bare)
                    .accessibilityLabel("Code block \(number)")
            }
            enclosed(text)
                .modifier(CodeBlockPulse(enclosure: look.markdown.codeBlock, pulse: look.markdown.codePulse,
                                         trigger: reached?.serial, still: reached?.still))
                .mascotBeside(reached?.serial)
        }
        .id(CodeBlockCue.Place(reply: reply, number: number))
    }

    /// The block's enclosure. It is drawn, so it is what Topo stands clear of, whole.
    @ViewBuilder
    private func enclosed(_ text: String) -> some View {
        let words = Text(text)
            .font(look.markdown.codeFont.monospaced())
            .foregroundStyle(look.markdown.codeInk)
        let enclosure = look.markdown.codeBlock
        Group {
            switch look.markdown.codeOverflow {
            case .scroll:
                ScrollView(.horizontal) {
                    words
                        .fixedSize()
                        .padding(.horizontal, enclosure.horizontalPadding)
                        .padding(.vertical, enclosure.verticalPadding)
                }
                .scrollIndicators(.hidden)
            case .wrap:
                words
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, enclosure.horizontalPadding)
                    .padding(.vertical, enclosure.verticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background { TurnShape.fill(enclosure) }
        .clipShape(RoundedRectangle(cornerRadius: enclosure.cornerRadius, style: .continuous))
        .mascotObstacle(bare)
    }

    static func marker(_ marker: Markdown.Marker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let n): "\(n)."
        }
    }

    /// `text` with its inline code runs in the look's code type, monospaced, and its code ink.
    static func styled(_ text: AttributedString, look: Look.Markdown) -> AttributedString {
        var text = text
        let code = text.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent?.contains(.code) == true ? range : nil
        }
        for range in code {
            text[range].swiftUI.font = look.codeFont.monospaced()
            text[range].swiftUI.foregroundColor = look.codeInk
        }
        return text
    }
}

/// The voice has reached a code block of a reply: the sentence that stands for it ("See code block
/// N.", `Speakable.line(forCodeBlock:)`) has begun. The transcript scrolls the block into view, its
/// enclosure pulses and Topo goes to stand on the other side of the transcript from it. Only a
/// reply being read aloud makes one (`Speaker.cue`), so a block that is only in the transcript is
/// never reached.
struct CodeBlockCue: Equatable, Sendable {
    /// The reply being read.
    var reply: TurnRef
    /// The block's number in the reply, as its caption draws it.
    var number: Int
    /// Counts cues, so the same block reached twice — the reply said again — is a new one.
    var serial: Int
    /// A moment of the pulse, in seconds from its start, drawn still and not animated: a
    /// preview's or a render's. Nil is the pulse as it plays.
    var still: Double?

    /// Where a code block is in the transcript, which it is scrolled to by.
    struct Place: Hashable {
        var reply: TurnRef?
        var number: Int?
    }

    var place: Place { Place(reply: reply, number: number) }
}

/// A code block's outline breathing when the voice reaches it: from nothing to the look's width
/// and opacity in its accent and back, `Look.Markdown.Pulse.cycles` times, eased all the way
/// (`Pulse.level`), over the enclosure's own shape. It plays each time `trigger` changes to a
/// new serial — not when it goes back to nil — or appears with a serial it has not played, and
/// draws nothing at rest; with `still` it draws that moment of the pulse and plays nothing.
struct CodeBlockPulse: ViewModifier {
    let enclosure: Look.Enclosure
    let pulse: Look.Markdown.Pulse
    let trigger: Int?
    var still: Double?
    /// The last cue this block played. The animator plays on every change of its trigger, and the
    /// voice moving on to another block turns this one's `trigger` back to nil, which is not a
    /// cue of this block: only a new serial is.
    @State private var played: Int?

    @ViewBuilder
    func body(content: Content) -> some View {
        let enclosure = enclosure, pulse = pulse
        if let still {
            content.overlay { Self.outline(pulse.level(at: still), enclosure: enclosure, pulse: pulse) }
        } else {
            content.keyframeAnimator(initialValue: pulse.duration, trigger: played) { content, time in
                content.overlay { Self.outline(pulse.level(at: time), enclosure: enclosure, pulse: pulse) }
            } keyframes: { _ in
                // The clock of the pulse, run from its start to its end; what it draws at each
                // moment is `level`, so the ease is the pulse's own and not the keyframe's.
                KeyframeTrack(\.self) {
                    MoveKeyframe(0)
                    LinearKeyframe(pulse.duration, duration: pulse.duration)
                }
            }
            .onChange(of: trigger) { _, cue in
                if let cue { played = cue }
            }
            // A block first drawn with its cue already set — a row the lazy transcript makes as
            // it scrolls to the block — has no change to see, so it plays as it appears: on the
            // pass after, since a change in the pass that makes the animator is not one it plays.
            .onAppear {
                guard let trigger, played != trigger else { return }
                DispatchQueue.main.async { played = trigger }
            }
        }
    }

    /// The outline at `level`, 0 at rest and 1 at the peak: its width and its opacity both
    /// that share of the look's, drawn inside the enclosure's edge so it covers nothing beside it.
    private nonisolated static func outline(_ level: Double, enclosure: Look.Enclosure,
                                            pulse: Look.Markdown.Pulse) -> some View {
        RoundedRectangle(cornerRadius: enclosure.cornerRadius, style: .continuous)
            .strokeBorder(pulse.accent.opacity(pulse.opacity * level), lineWidth: pulse.width * level)
            .allowsHitTesting(false)
    }
}
