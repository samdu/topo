import Foundation

/// A reply as the voice reads it: the same words the transcript draws, with what cannot be said
/// said the way a person would say it, and the markup that cannot be heard left out. The transcript
/// is never drawn from this; it is what `Speaker.speak` hands the voice.
///
/// The source is cut by the transcript's own parse (`Markdown.blocks`), so the voice reads the
/// words the screen shows and nothing of the syntax around them: emphasis, headings' `#`, list
/// markers and a link's address are gone before anything here sees the text, and a link is its
/// words. What is here is what the parse leaves that a voice cannot read:
///
/// - A fenced or indented code block is "See code block N.", N its number in the reply, which is
///   the caption the transcript draws over it (`Markdown.Block.codeNumber`): a voice reading
///   code out is noise, and the number is how the listener finds the block on the screen.
/// - A table is "A table with N rows.", N not counting the header: its cells read one after
///   another in a line are a list of words nobody can follow.
/// - A rule is nothing.
/// - In the words of every other block, a URL or an address is left exactly as written: it is
///   found first and no rule below runs inside it.
/// - Inline code is a literal, so its punctuation is said wherever it is, with no judgement of what
///   it names: every `/` "slash", every `.` with no space after it "dot" (`./look.json` "dot slash
///   look dot json", `x.c` "x dot c"), every `~` "tilde".
/// - Outside backticks, a file name or a path is read with its punctuation said: `look.json` "look
///   dot json", `/home/topo` "slash home slash topo", `~/.claude` "tilde slash dot claude",
///   `Apps/Client` "Apps slash Client", while `e.g.`, `3.5` and `and/or` are left as written. A
///   capitalised name of five letters or more (`CLAUDE.md`, `README.md`) is a word shouted, and
///   is read as the word; a shorter one is left as it is written, since it is more likely an
///   initialism the voice should spell.
///
/// Pocket reads text as it is given, with no normalisation beyond quotes and whitespace, so none
/// of this is done further down.
enum Speakable {
    static func text(from markdown: String) -> String {
        var lines: [String] = []
        var table: (identity: Int, rows: Int)?

        func finishTable() {
            if let done = table {
                lines.append("A table with \(done.rows) \(done.rows == 1 ? "row" : "rows").")
            }
            table = nil
        }

        for block in Markdown.blocks(markdown) {
            if let row = block.row {
                if table?.identity != row.table {
                    finishTable()
                    table = (row.table, 0)
                }
                if !row.header { table?.rows += 1 }
                continue
            }
            finishTable()
            switch block.kind {
            case .code:
                lines.append(block.codeNumber.map(line(forCodeBlock:)) ?? "See the code block.")
            case .rule:
                continue
            case .paragraph, .heading, .item:
                lines.append(words(block.text))
            }
        }
        finishTable()
        return lines.filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n")
    }

    /// What the voice says in code block `number`'s place, a line of its own.
    static func line(forCodeBlock number: Int) -> String { "See code block \(number)." }

    /// The code block a sentence of the spoken text stands for, when it is one: the line
    /// `line(forCodeBlock:)` writes, which `Speaker.sentences` always cuts as a sentence of its own,
    /// since it is a line of its own with one full stop at its end.
    static func codeBlock(saidBy sentence: String) -> Int? {
        let prefix = "See code block ", suffix = "."
        guard sentence.hasPrefix(prefix), sentence.hasSuffix(suffix) else { return nil }
        let digits = sentence.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let number = Int(digits), number > 0,
              line(forCodeBlock: number) == sentence else { return nil }
        return number
    }

    /// A run of what could be a path or a file name: an optional leading `/` or `~/`, then names
    /// of word characters, dots and hyphens separated by slashes. Not where it would start inside
    /// something else — after a word, a slash, a dot, a colon or an `@` — so the middle of a URL,
    /// an address or `and/or` is never the start of one.
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![\w/.~:@\-])(?:~?/)?[\w.\-]+(?:/[\w.\-]+)*/?"#)

    /// A name with an extension: a letter after every dot, so `3.5` and `v1.2` are not names.
    /// Before the first dot, two or more characters, or none (`.claude`), or one when the last
    /// extension is two or more (`a.py`): so `e.g.`, `i.e.` and `a.m.`, one letter either side,
    /// are not names.
    private static let dotted = try! NSRegularExpression(
        pattern: #"^(?:[\w\-]{2,}(?:\.[A-Za-z][\w\-]*)+|(?:\.[A-Za-z][\w\-]*)+|[\w\-](?:\.[A-Za-z][\w\-]*)*\.[A-Za-z][\w\-]+)$"#)

    /// A URL, with or without its scheme, or an address: left exactly as it is written.
    private static let address = try! NSRegularExpression(
        pattern: #"(?:[A-Za-z][A-Za-z0-9+.\-]*://|www\.)[^\s<>]+|[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+"#)

    /// The words of one block as they are said: inline code as a literal, everything else by the
    /// rules for bare text, and every URL and address in either left alone. Runs of spaces the
    /// saying leaves are closed up, and each line trimmed.
    static func words(_ text: AttributedString) -> String {
        var out = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let literal = run.inlinePresentationIntent?.contains(.code) == true
            out += outsideAddresses(piece, literal ? Self.literal : Self.bare)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    /// `say` applied to what lies between the URLs and addresses in `text`, and never to them.
    private static func outsideAddresses(_ text: String, _ say: (String) -> String) -> String {
        let source = text as NSString
        var out = ""
        var last = 0
        for match in address.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += say(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            out += source.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        return out + say(source.substring(from: last))
    }

    /// Inline code: every slash, tilde, and dot followed by something, said.
    private static func literal(_ code: String) -> String {
        let characters = Array(code)
        var out = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "/": out += " slash "
            case "~": out += " tilde "
            case "." where next.map { !$0.isWhitespace } == true: out += " dot "
            default: out.append(character)
            }
        }
        return out
    }

    /// Bare text: every path and file name in it read aloud, and nothing else touched.
    private static func bare(_ text: String) -> String {
        let source = text as NSString
        var out = ""
        var last = 0
        for match in candidate.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: last, length: match.range.location - last))
            out += spoken(source.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        out += source.substring(from: last)
        return out
    }

    /// One candidate said aloud, or as it is when it is neither a path nor a file name. A full
    /// stop or an ellipsis at its end is the sentence's, and stays.
    private static func spoken(_ candidate: String) -> String {
        var body = Substring(candidate)
        var stop = ""
        while body.hasSuffix(".") {
            body.removeLast()
            stop += "."
        }
        if body.count > 1, body.hasSuffix("/") { body.removeLast() }
        let segments = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isPath = body.hasPrefix("/") || body.hasPrefix("~/")
        guard let name = segments.last, isPath || isDotted(name) || isDirectory(segments) else {
            return candidate
        }
        let said = segments.map { segment -> String in
            if segment == "~" { return "tilde" }
            return isDotted(segment) ? file(segment) : segment
        }
        return said.joined(separator: " slash ").trimmingCharacters(in: .whitespaces) + stop
    }

    /// A relative path with no file at its end, told from `and/or`, `he/she`, `A/B`, `TCP/IP` and
    /// `1/2` by the shape of its names: every one a capitalised word (`Apps/Client`), or any one
    /// in CamelCase (`Packages/TopoCore`) or with an underscore (`src/my_module`), and none of
    /// them a number.
    private static func isDirectory(_ segments: [String]) -> Bool {
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty && !$0.allSatisfy(\.isNumber) }) else {
            return false
        }
        let capitalised = segments.allSatisfy { segment in
            segment.first?.isUppercase == true && segment.dropFirst().contains(where: \.isLowercase)
        }
        let camel = segments.contains { segment in
            zip(segment, segment.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        }
        return capitalised || camel || segments.contains { $0.contains("_") }
    }

    private static func isDotted(_ segment: String) -> Bool {
        dotted.firstMatch(in: segment, range: NSRange(location: 0, length: (segment as NSString).length)) != nil
    }

    /// `look.json` "look dot json", `.claude` "dot claude", `CLAUDE.md` "claude dot md".
    private static func file(_ name: String) -> String {
        let parts = name.split(separator: ".").map { part in
            let letters = part.filter(\.isLetter)
            let shouted = letters.count >= 5 && letters.allSatisfy(\.isUppercase)
            return shouted ? part.lowercased() : String(part)
        }
        return (name.hasPrefix(".") ? "dot " : "") + parts.joined(separator: " dot ")
    }
}
