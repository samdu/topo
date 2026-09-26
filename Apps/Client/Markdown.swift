import Foundation

/// Topo's words as blocks: paragraphs, headings, list items, fenced code and rules, each with its
/// inline styles still on it and with how many lists and how many quotes it sits inside. The parse
/// is Foundation's (`AttributedString(markdown:)` with the full syntax), which already marks every
/// run with the block it belongs to; what is here is the cut into blocks, since SwiftUI's `Text`
/// draws inline styles and nothing of a block.
///
/// A single newline stays a line break, as a reply's newlines always have, rather than folding into
/// a space as CommonMark folds it. Beyond that CommonMark's own readings stand: a line's leading
/// spaces are dropped, a tab-indented line is code, a backslash escapes what follows it, and a
/// link reference definition is not drawn.
enum Markdown {
    struct Block: Equatable {
        var kind: Kind
        /// How many lists the block sits inside: 0 at the margin, 1 for a top-level item and
        /// anything under it, and so on down.
        var depth: Int
        /// How many quotes the block sits inside: 0 at the margin, 2 inside a quote in a quote.
        /// Each level is drawn as a bar of its own.
        var quote: Int = 0
        /// How many of `depth`'s lists sit outside the outermost quote. A quote's bars stand in
        /// one column whatever is nested inside it, so the lists outside a quote lead the bars in
        /// and the lists inside it lead only what the bars enclose.
        var listsOutside: Int = 0
        /// The block's words with their inline intents — emphasis, strong, code, strikethrough —
        /// and nothing of the block's own markup. A link is its words and goes nowhere. Empty for
        /// a rule.
        var text: AttributedString
    }

    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// The first paragraph of a list item, which carries the item's marker. A later paragraph
        /// of the same item is a `paragraph` at the item's depth.
        case item(Marker)
        /// A fenced or indented code block, its text as written with the final newline gone.
        case code(language: String?)
        case rule
    }

    enum Marker: Equatable {
        case bullet
        case number(Int)
    }

    /// The blocks of `source`, kept by the words they were cut from: a transcript lays a reply
    /// out again each time it scrolls into view, and the parse is milliseconds a reply.
    static func cached(_ source: String) -> [Block] {
        let key = source as NSString
        if let kept = cache.object(forKey: key) { return kept.blocks }
        let blocks = blocks(source)
        cache.setObject(Kept(blocks), forKey: key)
        return blocks
    }

    private final class Kept: @unchecked Sendable {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Kept> = {
        let cache = NSCache<NSString, Kept>()
        cache.countLimit = 200
        return cache
    }()

    /// The blocks of `source`. A parse that fails, or that finds nothing to draw in a source that
    /// is not blank (a lone `#`, a bare fence), is the source as one plain paragraph, so no reply
    /// with words in it draws as nothing.
    static func blocks(_ source: String,
                       parse: (String) throws -> AttributedString = Markdown.parse) -> [Block] {
        guard let parsed = try? parse(source) else {
            return [Block(kind: .paragraph, depth: 0, text: AttributedString(source))]
        }
        var blocks: [Block] = []
        /// The list items whose marker has been drawn, so a second paragraph of one draws none.
        var marked: Set<Int> = []
        /// The table row being gathered, and its cells so far.
        var row: (identity: Int, depth: Int, quote: Int, outside: Int, text: AttributedString)?

        func finishRow() {
            if let done = row {
                blocks.append(Block(kind: .paragraph, depth: done.depth, quote: done.quote,
                                    listsOutside: done.outside, text: done.text))
            }
            row = nil
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let text = lineBroken(parsed[range])
            let components = intent?.components ?? []
            let isList = { (kind: PresentationIntent.Kind) in kind == .orderedList || kind == .unorderedList }
            let depth = components.filter { isList($0.kind) }.count
            let quote = components.filter { $0.kind == .blockQuote }.count
            // The components are innermost first, so the lists after the last quote are the ones
            // outside every quote; with no quote at all, every list is outside.
            let outside = components.lastIndex(where: { $0.kind == .blockQuote })
                .map { last in components[components.index(after: last)...].filter { isList($0.kind) }.count } ?? depth
            guard let innermost = components.first else {
                // A block of HTML carries no block intent, and is a paragraph of its words.
                finishRow()
                var text = text
                while text.characters.last == "\n" { text.characters.removeLast() }
                blocks.append(Block(kind: .paragraph, depth: 0, text: text))
                continue
            }
            if case .tableCell = innermost.kind, components.count > 1 {
                let rowIdentity = components[1].identity
                if row?.identity != rowIdentity {
                    finishRow()
                    row = (rowIdentity, depth, quote, outside, text)
                } else {
                    row?.text += AttributedString(Self.cellSeparator)
                    row?.text += text
                }
                continue
            }
            finishRow()
            func block(_ kind: Kind, _ text: AttributedString) -> Block {
                Block(kind: kind, depth: depth, quote: quote, listsOutside: outside, text: text)
            }
            switch innermost.kind {
            case .header(let level):
                blocks.append(block(.heading(level: level), text))
            case .codeBlock(let language):
                var code = String(text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                blocks.append(block(.code(language: language), AttributedString(code)))
            case .thematicBreak:
                blocks.append(block(.rule, AttributedString()))
            default:
                let item = components.dropFirst().first { if case .listItem = $0.kind { true } else { false } }
                if let item, case .listItem(let ordinal) = item.kind,
                   components.firstIndex(where: { $0.identity == item.identity }) == 1,
                   marked.insert(item.identity).inserted {
                    let ordered = components.dropFirst(2).first.map { $0.kind == .orderedList } ?? false
                    blocks.append(block(.item(ordered ? .number(ordinal) : .bullet), text))
                } else {
                    blocks.append(block(.paragraph, text))
                }
            }
        }
        finishRow()
        if blocks.isEmpty, !source.allSatisfy(\.isWhitespace) {
            return [Block(kind: .paragraph, depth: 0, text: AttributedString(source))]
        }
        return blocks
    }

    /// What stands between a table row's cells, since a table is drawn as its rows' words.
    static let cellSeparator = "  ·  "

    /// Foundation's parse with the full syntax, keeping the whitespace a reply is written with.
    static func parse(_ source: String) throws -> AttributedString {
        try AttributedString(markdown: source, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible))
    }

    /// Runs of one block with each soft break (parsed as a space) and hard break made a newline,
    /// so the lines of a paragraph break where they were written.
    private static func lineBroken(_ slice: AttributedSubstring) -> AttributedString {
        var text = AttributedString(slice)
        // A link is drawn as its words: nothing in a reply is somewhere a tap goes.
        text.link = nil
        let breaks = text.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent.map { $0.contains(.softBreak) || $0.contains(.lineBreak) } == true ? range : nil
        }
        for range in breaks.reversed() {
            text.replaceSubrange(range, with: AttributedString("\n"))
        }
        return text
    }
}
