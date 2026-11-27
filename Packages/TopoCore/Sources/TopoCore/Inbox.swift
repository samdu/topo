import Foundation

/// The words round what the hub's inbox tells the mind (`HubMind.hear`).
public enum Inbox {
    /// What the mind answers a batch with when none of it is worth the person's attention: the
    /// hub sends no notification for a reply that is exactly this.
    public static let nothing = "NOTHING TO REPORT"

    /// The line a batch is told under: it is in the person's side of the log, and they did not type it.
    public static let heading = """
    [From the inbox on this Mac: signals collected for you, not typed by the person. Tell them only what is worth their \
    attention, briefly and in your own words; they have not read what follows. When none of it is, reply with exactly \
    \(nothing) and nothing else.]
    """

    /// The batch a turn's text carries when the inbox sent it (`text` begins with the heading),
    /// without the heading; nil for any other turn. What a transcript draws folded, as input to
    /// the conversation and not the person's words.
    public static func batch(in text: String) -> String? {
        guard text.hasPrefix(heading) else { return nil }
        return String(text.dropFirst(heading.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a folded batch says it holds: its lines, or its words when it is one line.
    public static func size(of batch: String) -> String {
        let lines = batch.split(separator: "\n", omittingEmptySubsequences: true).count
        if lines > 1 { return "\(lines) lines" }
        let words = batch.split(whereSeparator: \.isWhitespace).count
        return words == 1 ? "1 word" : "\(words) words"
    }

    /// Whether `reply` says a batch held nothing for the person.
    public static func isNothing(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased() == nothing
    }
}
