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

    /// What the line says as well while the ear is resident and the voice is still coming.
    static let listening = "Topo can hear you now. Replies are written until the voice is in."

    /// Whether the line says `listening`: the ear resident, the voice neither resident nor
    /// failed, and the setup's meter standing, so it is said on an install and not on a launch.
    static func hearsFirst(earReady: Bool, voice: Voice.State, installing: Bool) -> Bool {
        earReady && installing && voice != .ready && voice != .failed
    }

    /// True only over a log that has been read and holds no turns, with nothing on the line or
    /// in flight, and the question not answered on this device. A debug build's fixture
    /// transcript is never asked over.
    static func asks(read: Bool, empty: Bool, waiting: Bool, busy: Bool, answered: Bool,
                     fixture: Bool = false) -> Bool {
        read && empty && !waiting && !busy && !answered && !fixture
    }

    /// Whether the question was answered when it stopped being asked: it was asked, and the log,
    /// still read, has a turn or words on the line. Nothing else that ends the asking is an
    /// answer: a turn in flight with nothing on the line (a demotion holds the harness busy while
    /// it saves), or a read taken away (a device taking primary back reads again).
    static func answered(asked: Bool, read: Bool, empty: Bool, waiting: Bool) -> Bool {
        asked && read && (waiting || !empty)
    }

    /// Topo as the chat draws him: holding the question up while it is asked.
    /// How opaque Topo is drawn: he goes with the flanks while the thumb is on the microphone,
    /// unless he is holding the question up, which stands until the answer is a turn.
    static func opacity(holding: Bool, asks: Bool, held: Double) -> Double {
        holding && !asks ? held : 1
    }

    static func drawn(_ state: MascotState, asks: Bool) -> MascotState {
        guard asks else { return state }
        var drawn = state
        drawn.sign = question
        return drawn
    }
}

/// The line under the transcript while the first-run question stands: the invitation, and the
/// way to the microphone while it is denied. The question is on Topo's sign, which is pixels, so
/// the line carries it to accessibility; and while he stands nowhere (no room for his reach at
/// the look's scale, a keyboard leaving none) the line says it in words, so it is never unseen.
struct FirstRunLine: View {
    var denied: Bool
    /// Topo stands nowhere, so nothing holds the question up.
    var unheld = false
    /// The ear is resident and the voice is still coming (`FirstRun.hearsFirst`).
    var hearsFirst = false
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: look.reading.spacing) {
            if unheld { Text(FirstRun.question) }
            Text(FirstRun.invitation)
            if denied { Text(FirstRun.denied) } else if hearsFirst { Text(FirstRun.listening) }
        }
        .font(look.reading.font)
        .foregroundStyle(look.reading.ink)
        .multilineTextAlignment(.center)
        .padding(.bottom, look.reading.spacing)
        .mascotObstacle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(denied: denied, hearsFirst: hearsFirst))
        .accessibilityIdentifier("first-run")
    }

    /// The question and every line drawn under it, for accessibility.
    static func label(denied: Bool, hearsFirst: Bool) -> String {
        let more = denied ? [FirstRun.denied] : hearsFirst ? [FirstRun.listening] : []
        return ([FirstRun.question, FirstRun.invitation] + more).joined(separator: " ")
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
