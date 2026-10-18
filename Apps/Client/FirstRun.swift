#if os(iOS)
import SwiftUI

/// When the first-run question is asked, and what asks it. The chat itself is the first-run
/// surface: Topo holds the question up on a sign over the empty transcript, the line under it
/// says the rest, and the answer is whatever the person first says or writes through the
/// composer, which goes on the harness's line as any turn does. Nothing is decided before the
/// log has been read: a returning person's log has turns, and a read that failed says nothing of
/// what it holds.
enum FirstRun {
    /// The question, on Topo's sign and in the line's accessibility label.
    static let question = "What did you forget this week?"
    /// What the line under the transcript says while the question stands.
    static let invitation = "or just start talking"
    /// What the line says as well while the microphone is denied: an ear still downloading its
    /// models is a wait, not something to go and allow.
    static let denied = "Topo can't hear you without the microphone. You can type instead, or allow it in Settings."

    /// True only over a log that has been read and holds no turns, with nothing on the line or
    /// in flight, and the question not answered on this device. A debug build's fixture
    /// transcript is never asked over.
    static func asks(read: Bool, empty: Bool, waiting: Bool, busy: Bool, answered: Bool,
                     fixture: Bool = false) -> Bool {
        read && empty && !waiting && !busy && !answered && !fixture
    }

    /// Whether the question was answered when it stopped being asked: it was asked over a read
    /// log, and is not asked now over a log still read, so something reached the line or the
    /// log. A log not read now (a device taking primary back reads again) answers nothing.
    static func answered(asked: Bool, asks: Bool, read: Bool) -> Bool { asked && !asks && read }

    /// Topo as the chat draws him: holding the question up while it is asked.
    static func drawn(_ state: MascotState, asks: Bool) -> MascotState {
        guard asks else { return state }
        var drawn = state
        drawn.sign = question
        return drawn
    }
}

/// The line under the transcript while the first-run question stands: the invitation, and the
/// way to the microphone while it is denied. The question itself is on Topo's sign, which is
/// pixels, so the line carries it to accessibility.
struct FirstRunLine: View {
    var denied: Bool
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: look.reading.spacing) {
            Text(FirstRun.invitation)
            if denied { Text(FirstRun.denied) }
        }
        .font(look.reading.font)
        .foregroundStyle(look.reading.ink)
        .multilineTextAlignment(.center)
        .padding(.bottom, look.reading.spacing)
        .mascotObstacle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([FirstRun.question, FirstRun.invitation] + (denied ? [FirstRun.denied] : [])).joined(separator: " "))
        .accessibilityIdentifier("first-run")
    }
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
