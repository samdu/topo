#if os(iOS)
import SwiftUI

/// When the first-run question is asked. Nothing is decided before the log has been read: a
/// returning person's log has turns, and a read that failed says nothing of what it holds.
enum FirstRun {
    /// True only over a log that has been read and holds no turns, with nothing on the line or
    /// in flight, the person not at the chat's own microphone or field, and the question not
    /// answered on this device. `engaged` is why the question never arrives over a session the
    /// chat already holds: the composer is usable while the log is unread, and a press begun
    /// there ends there. A debug build's fixture transcript is never asked over.
    static func asks(read: Bool, empty: Bool, waiting: Bool, busy: Bool, engaged: Bool, answered: Bool,
                     fixture: Bool = false) -> Bool {
        read && empty && !waiting && !busy && !engaged && !answered && !fixture
    }

    /// The person's hand is on the chat: its own microphone is open or opening (the session is
    /// the chat's from the press until it is torn down), its field has the focus, or there are
    /// words in its row.
    @MainActor
    static func engaged(voice: VoiceInput, row: NextTurn, focused: Bool) -> Bool {
        voice.owner == .chat || focused || row.typing || !row.text.isEmpty
    }

    /// The answer becomes the first turn: on the line under one nonce before the question goes,
    /// so the outbox is the one place it is kept. `mark` is what records the question as
    /// answered, called once the words are on the line. Answers false, and does nothing, for a
    /// second answer or one with no words in it.
    @MainActor
    static func answer(_ text: String, answered: Bool, via harness: Harness, mark: () -> Void) -> Bool {
        guard !answered, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        harness.willSend(text)
        mark()
        return true
    }

    /// Whether the question stands: while it is asked, and until an answer said into its own
    /// microphone has been heard, so a turn the log brings while the ear decodes does not take
    /// the screen, and the answer with it, from under the person.
    static func stands(hearing: Bool, asks: Bool) -> Bool { asks || hearing }
}

/// What stands where the transcript will, until the first read of the log returns.
struct ReadingLog: View {
    @Environment(\.look) private var look

    static let words = "Reading your conversation…"

    /// It stands while the log is unread and nothing of the person's is drawn there: words said
    /// before the read are on the page as any turn on its way is, and are never covered.
    static func stands(read: Bool, drawn: Bool) -> Bool { !read && !drawn }

    var body: some View {
        VStack(spacing: look.reading.spacing) {
            OctopusMark().frame(width: look.reading.markSize, height: look.reading.markSize)
            ProgressView()
            Text(Self.words)
                .font(look.reading.font)
                .foregroundStyle(look.reading.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reading-log")
    }
}
#endif
