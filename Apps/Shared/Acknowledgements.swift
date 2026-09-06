import Foundation

/// `THIRD-PARTY`, read out of the app's own bundle.
///
/// The file is the acknowledgements screen rather than the source for one: it
/// is copied into every bundle as a resource and parsed here, so a licence
/// added to the file is on the screen in the next build and the two cannot
/// drift apart. Womble parses the same file with its own copy of this, since
/// it shares no code with the client.
///
/// The format is in the file, and it is small on purpose: a `## ` heading
/// opens an entry, `Key: value` lines under it are its fields in the order
/// they are written, and everything before the first heading is the note.
struct Acknowledgements: Equatable, Sendable {
    /// The paragraphs above the first entry: what shipping in a bundle means
    /// here, and why the list is as short as it is.
    var note: [String] = []
    var entries: [Entry] = []

    struct Entry: Equatable, Sendable, Identifiable {
        var name: String
        var fields: [Field] = []
        var id: String { name }
    }

    struct Field: Equatable, Sendable, Identifiable {
        var key: String
        var value: String
        var id: String { key }
    }

    /// The one in this bundle, or nil when it is not there — which is a build
    /// that forgot the resource, and the screen says so rather than showing an
    /// empty list that reads as "nothing was borrowed".
    static func bundled(in bundle: Bundle = .main) -> Acknowledgements? {
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
                // The title is the file's, not the screen's, and blank lines
                // are what separates one paragraph of the note from the next.
                if line.hasPrefix("# ") { continue }
                if line.isEmpty { endParagraph() } else { paragraph += paragraph.isEmpty ? line : " " + line }
            } else if !line.isEmpty {
                var entry = acknowledgements.entries.removeLast()
                if let colon = line.firstIndex(of: ":"), Self.isKey(line[line.startIndex..<colon]) {
                    entry.fields.append(Field(key: String(line[line.startIndex..<colon]),
                                              value: String(line[line.index(after: colon)...])
                                                  .trimmingCharacters(in: .whitespaces)))
                } else if !entry.fields.isEmpty {
                    // A wrapped line belongs to the field above it.
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
