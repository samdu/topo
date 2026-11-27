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

    /// Whether `reply` says a batch held nothing for the person.
    public static func isNothing(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased() == nothing
    }
}
