import Foundation

/// Topo's words as blocks: paragraphs, headings, list items, fenced code, tables, images and rules, each
/// with its inline styles still on it and with how many lists and how many quotes it sits inside. The parse
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
        /// and nothing of the block's own markup. A web link's run carries its address (`link`),
        /// written out or a bare URL the parse linked, and is the one part of a reply a tap
        /// follows; a link to anything else is its words (`opens`). Empty for
        /// a rule, and for a table, whose words are its cells'.
        var text: AttributedString
        /// A code block's number in the reply, from 1 in the order they are written, nil for any
        /// other block. The transcript draws it as the block's caption and the voice says it in
        /// the block's place, so the two always name the same block.
        var codeNumber: Int? = nil
    }

    /// One row of a table: a cell for every column of the table, in order, an empty one where
    /// the source wrote nothing between two bars. The columns are the header's: a cell a row
    /// writes past them is one the parse does not keep, so it is in no row.
    struct TableRow: Equatable {
        var cells: [TableCell]
    }

    struct TableCell: Equatable {
        /// The cell's words with their inline intents, as a paragraph's are.
        var text: AttributedString
        /// Its column's alignment, as the delimiter row wrote it (`:--`, `:-:`, `--:`).
        var alignment: ColumnAlignment = .leading
    }

    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// The first paragraph of a list item, which carries the item's marker. A later paragraph
        /// of the same item is a `paragraph` at the item's depth.
        case item(Marker)
        /// A fenced or indented code block, its text as written with the final newline gone.
        case code(language: String?)
        /// A table: the header row, whose cells name the columns, and the rows under it. Every
        /// row holds a cell for every column.
        case table(header: TableRow, rows: [TableRow])
        /// An image written in a block: its source as the reply wrote it, and its alternative
        /// text. (One written as a link's words is also still that link, on its alternative
        /// text, in the block it was written in.) It is a block of its own, after the block it was written in,
        /// which keeps its words. What the source names is `place(ofImage:)`.
        case image(source: String, alt: String)
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
        /// The images written as a link's words, which the parse keeps as that link alone.
        var linked = linkedImages(in: source)
        /// The list items whose marker has been drawn, so a second paragraph of one draws none.
        var marked: Set<Int> = []
        /// The code blocks so far, which numbers the next.
        var codeBlocks = 0
        /// The table being gathered: where it sits, its columns' alignments, and its rows so
        /// far, each cell kept by the column the parse says it is in — the parse makes no run
        /// for an empty cell, so a row's cells are not its columns in order — and each row by
        /// the place the parse says it has in the table, since a row of empty cells has no run
        /// at all and is known only by the place it leaves between the rows round it.
        var table: (identity: Int, depth: Int, quote: Int, outside: Int, columns: [ColumnAlignment],
                    header: [Int: AttributedString],
                    rows: [Int: [Int: AttributedString]],
                    images: [Kind])?

        func finishTable() {
            guard let done = table else { return }
            table = nil
            let widest = ([done.header] + done.rows.values).flatMap(\.keys).max().map { $0 + 1 } ?? 0
            let columns = max(done.columns.count, widest)
            func row(_ cells: [Int: AttributedString]) -> TableRow {
                TableRow(cells: (0..<columns).map { column in
                    TableCell(text: cells[column] ?? AttributedString(),
                              alignment: column < done.columns.count ? done.columns[column] : .leading)
                })
            }
            // The header is row 0 and the rows under it count from 1; a place no run names is a
            // row of empty cells. (One at the table's very end leaves no place to know it by.)
            let rows = done.rows.keys.max().map { last in (1...max(last, 1)).map { row(done.rows[$0] ?? [:]) } } ?? []
            blocks.append(Block(kind: .table(header: row(done.header), rows: rows),
                                depth: done.depth, quote: done.quote, listsOutside: done.outside,
                                text: AttributedString()))
            // An image written in a cell is drawn under the table.
            for image in done.images {
                blocks.append(Block(kind: image, depth: done.depth, quote: done.quote, listsOutside: done.outside,
                                    text: AttributedString()))
            }
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            var text = lineBroken(parsed[range])
            let images = takeImages(from: &text) + linkedImages(in: text, of: &linked)
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
                finishTable()
                var text = text
                while text.characters.last == "\n" { text.characters.removeLast() }
                blocks.append(Block(kind: .paragraph, depth: 0, text: text))
                continue
            }
            // A cell's components are the cell, its row, then its table.
            if case .tableCell(let column) = innermost.kind, components.count > 2,
               case .table(let columns) = components[2].kind {
                let (rowIntent, tableIntent) = (components[1], components[2])
                if table?.identity != tableIntent.identity {
                    finishTable()
                    table = (tableIntent.identity, depth, quote, outside, columns.map(ColumnAlignment.init), [:], [:], [])
                }
                table?.images += images
                if rowIntent.kind == .tableHeaderRow {
                    table?.header[column, default: AttributedString()] += text
                } else if case .tableRow(let index) = rowIntent.kind {
                    table?.rows[index, default: [:]][column, default: AttributedString()] += text
                }
                continue
            }
            finishTable()
            func block(_ kind: Kind, _ text: AttributedString) -> Block {
                Block(kind: kind, depth: depth, quote: quote, listsOutside: outside, text: text)
            }
            let before = blocks.count
            defer {
                if !images.isEmpty {
                    // A block that held nothing but its images is not drawn as an empty one.
                    if blocks.count > before, blocks[before].text.characters.allSatisfy(\.isWhitespace) {
                        blocks.remove(at: before)
                    }
                    blocks += images.map { block($0, AttributedString()) }
                }
            }
            switch innermost.kind {
            case .header(let level):
                blocks.append(block(.heading(level: level), text))
            case .codeBlock(let language):
                var code = String(text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                var fence = block(.code(language: language), AttributedString(code))
                codeBlocks += 1
                fence.codeNumber = codeBlocks
                blocks.append(fence)
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
        finishTable()
        if blocks.isEmpty, !source.allSatisfy(\.isWhitespace) {
            return [Block(kind: .paragraph, depth: 0, text: AttributedString(source))]
        }
        return blocks
    }

    /// Foundation's parse with the full syntax, keeping the whitespace a reply is written with.
    static func parse(_ source: String) throws -> AttributedString {
        try AttributedString(markdown: source, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible))
    }

    /// Takes the images out of a block's words, in order, and trims the space they leave at its
    /// ends. The parse marks an image as a run carrying its source whose characters are its
    /// alternative text, or the object replacement character when it has none.
    private static func takeImages(from text: inout AttributedString) -> [Kind] {
        var images: [Kind] = []
        var ranges: [Range<AttributedString.Index>] = []
        for (source, range) in text.runs[\.imageURL] {
            guard let source else { continue }
            let alt = String(text[range].characters).replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            images.append(.image(source: source.relativeString, alt: alt))
            ranges.append(range)
        }
        guard !images.isEmpty else { return [] }
        for range in ranges.reversed() { text.removeSubrange(range) }
        while text.characters.first?.isWhitespace == true { text.characters.removeFirst() }
        while text.characters.last?.isWhitespace == true { text.characters.removeLast() }
        return images
    }

    /// An image written as a link's words, `[![alt](source)](address)`: its alternative text,
    /// its source and the link's address, as the reply wrote them.
    private struct LinkedImage {
        var alt: String
        var source: String
        var address: String
    }

    /// The images `source` writes as a link's words, in order. The parse keeps such an image
    /// as its alternative text on the link's run and says nothing of its source, so the source
    /// is read from the reply as written: the plain form of it, `[![alt](source)](address)`
    /// on one line with no bracket nested in it. One written another way is still its words
    /// and its link, and so is one written where it is not a link at all — in code — which
    /// this cannot tell apart, so it is matched to a link only by that link's own address and
    /// words (`linkedImages(in:of:)`).
    ///
    /// It is one pass over the reply's bytes: each `[![` is read forward a part at a time, each
    /// part to a length it may not pass, and a part that does not fit ends that reading there.
    private static func linkedImages(in source: String) -> [LinkedImage] {
        guard source.contains("[![") else { return [] }
        let bytes = Array(source.utf8)
        let (open, close, round, unround, less, more, bang, slash, line) =
            (UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"),
             UInt8(ascii: ">"), UInt8(ascii: "!"), UInt8(ascii: "\\"), UInt8(ascii: "\n"))
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
        /// From `at`, the bytes up to the first of `ends`, and where that is: nil when one of
        /// `never`, a line's end, the text's end or the part's limit comes first.
        func part(from at: Int, to ends: [UInt8], never: [UInt8], limit: Int) -> (text: String, end: Int)? {
            var index = at
            while index < bytes.count, index - at <= limit {
                let byte = bytes[index]
                if ends.contains(byte) { return (String(decoding: bytes[at..<index], as: UTF8.self), index) }
                if byte == line || never.contains(byte) { return nil }
                index += 1
            }
            return nil
        }
        /// An address in round brackets from the byte after the `(`: bare, or in angle brackets.
        func address(from at: Int) -> (text: String, end: Int)? {
            var index = at
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == less {
                guard let found = part(from: index + 1, to: [more], never: [less], limit: partLimit) else { return nil }
                return found.text.isEmpty ? nil : (found.text.replacingOccurrences(of: " ", with: "%20"), found.end + 1)
            }
            guard let found = part(from: index, to: [unround, 0x20, 0x09], never: [open, close, round, less], limit: partLimit),
                  !found.text.isEmpty else { return nil }
            return found
        }
        var images: [LinkedImage] = []
        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == open, bytes[index + 1] == bang, bytes[index + 2] == open,
                  index == 0 || bytes[index - 1] != slash else {
                index += 1
                continue
            }
            let start = index
            index += 3
            guard let alt = part(from: start + 3, to: [close], never: [open], limit: partLimit),
                  alt.end + 1 < bytes.count, bytes[alt.end + 1] == round,
                  let source = address(from: alt.end + 2),
                  // A title, if there is one, and the bracket that closes the image.
                  let closed = part(from: source.end, to: [unround], never: [round], limit: partLimit),
                  // Whatever else the link's words are, and the bracket that closes them.
                  let label = part(from: closed.end + 1, to: [close], never: [open], limit: partLimit),
                  label.end + 1 < bytes.count, bytes[label.end + 1] == round,
                  let link = address(from: label.end + 2) else { continue }
            images.append(LinkedImage(alt: alt.text, source: source.text, address: link.text))
            index = link.end
        }
        return images
    }

    /// The most bytes any one part of a linked image — its alternative text, its source, its
    /// address — is read to.
    private static let partLimit = 2048

    /// The image blocks for the links of `text` that were written round an image: each linked
    /// run whose address and words are those of one still in `pending`, which leaves it. The
    /// run stays as it is — the image's alternative text, linked — and the image is drawn
    /// after its block as any other.
    private static func linkedImages(in text: AttributedString, of pending: inout [LinkedImage]) -> [Kind] {
        guard !pending.isEmpty else { return [] }
        var images: [Kind] = []
        for (link, range) in text.runs[\.link] {
            guard let link else { continue }
            let words = String(text[range].characters)
            guard let found = pending.firstIndex(where: {
                URL(string: $0.address) == link && words.contains($0.alt.trimmingCharacters(in: .whitespaces))
            }) else { continue }
            let image = pending.remove(at: found)
            images.append(.image(source: image.source, alt: image.alt.trimmingCharacters(in: .whitespaces)))
        }
        return images
    }

    /// Where an image's source says its bytes are.
    enum ImagePlace: Equatable {
        /// A file, by the path the reply wrote: the guest's own path, absolute or from its
        /// home, which only the guest can resolve.
        case file(String)
        /// A web address, which is never fetched: its picture is not drawn, and the address is
        /// offered as a link.
        case web(URL)
        /// Neither: another scheme's address, or nothing at all.
        case neither
    }

    /// Where the image a reply names by `source` is: a web address, which is recognised and
    /// not fetched, or a path, as the reply wrote it with its percent escapes read. A path is
    /// not judged here — whether there is a file at it, and whether it may be read, is the
    /// guest's own answer (`ReplyImage`).
    static func place(ofImage source: String) -> ImagePlace {
        let source = source.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: source), url.scheme != nil {
            return opens(url) ? .web(url) : .neither
        }
        let path = source.removingPercentEncoding ?? source
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return .neither }
        return .file(path)
    }

    /// Whether a link is one a tap may follow: a web address, `http` or `https` with a host. Any
    /// other scheme — the app's own, another app's, `file`, `tel`, `javascript` — would hand a
    /// reply's words a way into something other than a browser, so its run is words alone.
    static func opens(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return link.host().map { !$0.isEmpty } == true
    }

    /// Runs of one block with each soft break (parsed as a space) and hard break made a newline,
    /// so the lines of a paragraph break where they were written.
    private static func lineBroken(_ slice: AttributedSubstring) -> AttributedString {
        var text = AttributedString(slice)
        // A link stays on its run only where it is one a tap may follow (`opens`); any other is
        // its words.
        for (link, range) in text.runs[\.link] where link.map(opens) == false {
            text[range].link = nil
        }
        let breaks = text.runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent.map { $0.contains(.softBreak) || $0.contains(.lineBreak) } == true ? range : nil
        }
        for range in breaks.reversed() {
            text.replaceSubrange(range, with: AttributedString("\n"))
        }
        return text
    }
}

private extension Markdown.ColumnAlignment {
    init(_ column: PresentationIntent.TableColumn) {
        switch column.alignment {
        case .center: self = .center
        case .right: self = .trailing
        default: self = .leading
        }
    }
}
