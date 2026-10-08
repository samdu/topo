/// The words of one reply, gathered over the assistant messages of its turn: what the model said
/// before a tool call, between two, and after the last, in the order it said them.
///
/// A turn that runs a tool is several assistant messages, and the reply is all of their words: a
/// message's text blocks run on from one another as the model wrote them, a message with no words
/// in it — one that only thought, or only called a tool — adds nothing, and one message's words
/// are parted from the next's by a paragraph break. Tool calls, their results and thinking are no
/// part of it.
///
/// The three places that hold a reply's words build them here, so they hold the same bytes: the
/// row drawn while the guest writes (`Harness.writing`, from the deltas), the reply written to
/// the log when the turn ends (`GuestBridge`, from the whole text blocks), and the reply read
/// back from Claude Code's transcript after a crash (`GuestTranscript`).
public struct ReplyWords: Sendable, Equatable {
    /// What parts one message's words from the next's.
    public static let separator = "\n\n"

    /// Each message's words so far, in order, empty for a message that has written none.
    private var messages: [String] = []
    /// The message `append(_:of:)` last wrote to, by its id.
    private var open: String??

    public init() {}

    /// A message begun: what is appended next is its words and not the last one's.
    public mutating func begin() {
        messages.append("")
        open = nil
    }

    /// More of the words of the message last begun, beginning one if none has been.
    public mutating func append(_ text: String) {
        if messages.isEmpty { messages.append("") }
        messages[messages.count - 1] += text
    }

    /// More of the words of the message `id`, which is begun here when it is not the message the
    /// last words were appended to. Two messages with no id are one message.
    public mutating func append(_ text: String, of id: String?) {
        if open != .some(id) {
            messages.append("")
            open = .some(id)
        }
        messages[messages.count - 1] += text
    }

    /// The reply: every message that has words, in order, a paragraph break between them.
    public var text: String {
        messages.filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: Self.separator)
    }
}
