import Foundation

/// Topo's words as blocks: paragraphs, headings, list items, quotes, fenced code and rules, each
/// with its inline styles still on it. The parse is Foundation's (`AttributedString(markdown:)`
/// with the full syntax), which already marks every run with the block it belongs to; what is
/// here is the cut into blocks, since SwiftUI's `Text` draws inline styles and nothing of a block.
///
/// A reply with no markup in it is one paragraph of itself: a single newline stays a line break,
/// as a reply's newlines always have, rather than folding into a space as CommonMark folds it.
enum Markdown {
    struct Block: Equatable {
        var kind: Kind
        /// How many lists the block sits inside: 0 at the margin, 1 for a top-level item and
        /// anything under it, and so on down.
        var depth: Int
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
        /// A paragraph inside a block quote.
        case quote
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

    /// The blocks of `source`. A parse that fails is the source as one plain paragraph, so no
    /// reply ever draws as nothing.
    static func blocks(_ source: String,
                       parse: (String) throws -> AttributedString = Markdown.parse) -> [Block] {
        guard let parsed = try? parse(source) else {
            return [Block(kind: .paragraph, depth: 0, text: AttributedString(source))]
        }
        var blocks: [Block] = []
        /// The list items whose marker has been drawn, so a second paragraph of one draws none.
        var marked: Set<Int> = []
        /// The table row being gathered, and its cells so far.
        var row: (identity: Int, depth: Int, text: AttributedString)?

        func finishRow() {
            if let done = row { blocks.append(Block(kind: .paragraph, depth: done.depth, text: done.text)) }
            row = nil
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let text = lineBroken(parsed[range])
            let components = intent?.components ?? []
            let depth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
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
                    row = (rowIdentity, depth, text)
                } else {
                    row?.text += AttributedString(Self.cellSeparator)
                    row?.text += text
                }
                continue
            }
            finishRow()
            switch innermost.kind {
            case .header(let level):
                blocks.append(Block(kind: .heading(level: level), depth: depth, text: text))
            case .codeBlock(let language):
                var code = String(text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                blocks.append(Block(kind: .code(language: language), depth: depth, text: AttributedString(code)))
            case .thematicBreak:
                blocks.append(Block(kind: .rule, depth: depth, text: AttributedString()))
            default:
                let item = components.dropFirst().first { if case .listItem = $0.kind { true } else { false } }
                let quoted = components.contains { $0.kind == .blockQuote }
                if let item, case .listItem(let ordinal) = item.kind,
                   components.firstIndex(where: { $0.identity == item.identity }) == 1,
                   marked.insert(item.identity).inserted {
                    let ordered = components.dropFirst(2).first.map { $0.kind == .orderedList } ?? false
                    blocks.append(Block(kind: .item(ordered ? .number(ordinal) : .bullet), depth: depth, text: text))
                } else {
                    blocks.append(Block(kind: quoted ? .quote : .paragraph, depth: depth, text: text))
                }
            }
        }
        finishRow()
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
