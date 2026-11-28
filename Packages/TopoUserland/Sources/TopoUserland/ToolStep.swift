import Foundation

/// A tool call of the turn's own as the transcript's work row draws it: a one-line summary for
/// the line, and the whole input for the step opened. Both are read from the call's input here,
/// where the stream is parsed, so nothing downstream holds the input as a structure.
///
/// The summary never carries a command: a Bash call reads as the description the model wrote
/// for a person, a file tool as the file's name, a search as its pattern or query, a fetch as its
/// host, and an MCP tool as `server · tool`. The input in full is the step's alone, on the device
/// that ran the turn (`docs/chat.md`, *The work row*): a command can carry a connection's token.
public enum ToolStep {
    /// The most a summary holds, a line of the row.
    public static let summaryMax = 80
    /// The most of a call's input kept, and of a result's text, in characters: the first three
    /// quarters and the last quarter, since the end of a long result is where its error is.
    public static let inputMax = 32_000
    public static let resultMax = 64_000

    public static func summary(name: String, input: Any?) -> String {
        let i = input as? [String: Any] ?? [:]
        func string(_ key: String) -> String { i[key] as? String ?? "" }
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return oneLine("\(parts[0]) · \(parts[1...].joined(separator: "__"))") }
        }
        switch name {
        case "Bash": return oneLine(string("description"))
        case "Read", "Edit", "Write", "MultiEdit": return oneLine((string("file_path") as NSString).lastPathComponent)
        case "NotebookEdit", "NotebookRead": return oneLine((string("notebook_path") as NSString).lastPathComponent)
        case "Grep", "Glob": return oneLine(string("pattern"))
        case "WebSearch", "ToolSearch": return oneLine(string("query"))
        case "WebFetch": return oneLine(URL(string: string("url"))?.host() ?? "")
        case "Agent", "Task": return oneLine(string("description"))
        case "Skill": return oneLine(string("skill"))
        default: return oneLine(string("description"))
        }
    }

    /// A call's input as a person reads it: one `key: value` per argument, a string verbatim and
    /// anything else as JSON. What says where a call acts comes first (`leading`), then what it
    /// does, then the rest in alphabetical order.
    public static func render(input: Any?) -> String {
        guard let i = input as? [String: Any] else { return input.map(json) ?? "" }
        let order = leading.filter { i[$0] != nil } + i.keys.sorted().filter { !leading.contains($0) }
        return order.map { key in
            let value = i[key].map { $0 as? String ?? json($0) } ?? ""
            return value.contains("\n") ? "\(key):\n\(value)" : "\(key): \(value)"
        }.joined(separator: "\n")
    }

    /// `text` within `max` characters, the note of the cut included: three quarters of what is
    /// kept from its head, a quarter from its tail, and whether a middle was cut.
    public static func cap(_ text: String, _ max: Int) -> (text: String, cut: Bool) {
        let count = text.count
        guard count > max else { return (text, false) }
        let note = { (gone: Int) in "\n\n… \(gone) characters not kept …\n\n" }
        let room = Swift.max(0, max - note(count).count)
        let head = room * 3 / 4, tail = room - head
        return ("\(text.prefix(head))\(note(count - room))\(text.suffix(tail))", true)
    }

    static let leading = ["file_path", "notebook_path", "path", "url", "command", "pattern", "query", "description"]

    private static func oneLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > summaryMax ? String(line.prefix(summaryMax - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
}
