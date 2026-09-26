import SwiftUI

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
            code(String(block.text.characters))
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

    /// A fenced block in its own enclosure, scrolled sideways or wrapped as the look says. The
    /// enclosure is drawn, so it is what Topo stands clear of, whole.
    @ViewBuilder
    private func code(_ text: String) -> some View {
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
