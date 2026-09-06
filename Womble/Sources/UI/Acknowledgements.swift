import Foundation

/// `THIRD-PARTY`, read out of Womble's own bundle.
///
/// The client parses the same file with its own copy of this
/// (`Apps/Shared/Acknowledgements.swift`); Womble shares no code with it, by
/// design, so the file is what the two have in common. The format is written
/// in the file: a `## ` heading opens an entry, `Key: value` lines under it
/// are its fields, and everything before the first heading is the note.
struct Acknowledgements: Equatable {
    var note: [String] = []
    var entries: [Entry] = []

    struct Entry: Equatable {
        var name: String
        var fields: [Field] = []
    }

    struct Field: Equatable {
        var key: String
        var value: String
    }

    /// The one in this bundle, or nil when it was left out of the build.
    static func bundled(in bundle: Bundle = Bundle.main) -> Acknowledgements? {
        guard let url = bundle.url(forResource: "THIRD-PARTY", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Acknowledgements {
        var acknowledgements = Acknowledgements()
        var paragraph = ""

        func endParagraph() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { acknowledgements.note.append(trimmed) }
            paragraph = ""
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                endParagraph()
                acknowledgements.entries.append(Entry(name: String(line.dropFirst(3))))
            } else if acknowledgements.entries.isEmpty {
                if line.hasPrefix("# ") { continue }
                if line.isEmpty { endParagraph() } else { paragraph += paragraph.isEmpty ? line : " " + line }
            } else if !line.isEmpty {
                var entry = acknowledgements.entries.removeLast()
                if let colon = line.firstIndex(of: ":"), isKey(line[line.startIndex..<colon]) {
                    entry.fields.append(Field(key: String(line[line.startIndex..<colon]),
                                              value: String(line[line.index(after: colon)...])
                                                  .trimmingCharacters(in: .whitespaces)))
                } else if !entry.fields.isEmpty {
                    entry.fields[entry.fields.count - 1].value += " " + line
                }
                acknowledgements.entries.append(entry)
            }
        }
        endParagraph()
        return acknowledgements
    }

    /// What opens a field rather than a wrapped line: a word or two of
    /// letters, so the colon in a URL does not start a field called `https`.
    private static func isKey(_ candidate: Substring) -> Bool {
        return !candidate.isEmpty && candidate.count <= 20
            && candidate.allSatisfy { $0.isLetter || $0 == " " }
    }
}
