import SwiftUI

/// Topo's words drawn as their blocks (`Markdown.blocks`): paragraphs and headings as text, list
/// items behind their markers, quotes behind a bar, rules, and fenced code in an enclosure of its
/// own. Every value is the look's (`Look.Markdown`), and a paragraph is drawn in the transcript's
/// own type and ink, as the transcript draws words.
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
                row(block)
                    .padding(.leading, lead(block))
            }
        }
    }

    /// How far a block is led in: a list item by the lists round it less its own, so its marker
    /// sits where its list starts, and anything else inside an item by all of them, so it sits
    /// one indent in from the item's marker.
    private func lead(_ block: Markdown.Block) -> CGFloat {
        if case .item = block.kind { return CGFloat(max(block.depth - 1, 0)) * look.markdown.listIndent }
        return CGFloat(block.depth) * look.markdown.listIndent
    }

    @ViewBuilder
    private func row(_ block: Markdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            words(block.text, font: look.transcript.bodyFont, ink: look.transcript.text)
        case .heading(let level):
            words(block.text, font: look.markdown.headingFont(level), ink: look.transcript.text)
                .accessibilityAddTraits(.isHeader)
        case .item(let marker):
            HStack(alignment: .firstTextBaseline, spacing: look.markdown.markerSpacing) {
                Text(Self.marker(marker))
                    .font(look.transcript.bodyFont)
                    .foregroundStyle(look.markdown.marker)
                    .mascotLines(bare)
                words(block.text, font: look.transcript.bodyFont, ink: look.transcript.text)
            }
        case .quote:
            HStack(alignment: .top, spacing: look.markdown.markerSpacing) {
                Rectangle()
                    .fill(look.markdown.quoteBar)
                    .frame(width: look.markdown.quoteBarWidth)
                    .mascotObstacle(bare)
                words(block.text, font: look.transcript.bodyFont, ink: look.markdown.quoteText)
            }
            // The bar is as tall as the words beside it.
            .fixedSize(horizontal: false, vertical: true)
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
