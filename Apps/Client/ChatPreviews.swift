#if DEBUG
import SwiftUI
import TopoCore

/// Fixture turns for the canvas: a conversation the log could have held, with no CloudKit,
/// harness or voice behind it. Debug builds only, so nothing here ships.
enum PreviewTurns {
    static let phone = DeviceID("preview-phone")
    static let hub = DeviceID("preview-hub")

    static let short: [Turn] = make([
        (.person, "What's the capital of France?"),
        (.assistant, "Paris."),
    ])

    /// Turns that fit a phone-sized stage with the composer over them, one of which is long
    /// enough to wrap and so to be bounded by the column's width.
    ///
    /// What a compared still must not contain is anything the system chooses the resting place
    /// of. A transcript taller than its stage is scrolled to its end through a `LazyVStack`, and
    /// where that comes to rest depends on how many rows had been made when the scroll ran — so
    /// two drawings of one look settle a pixel or two apart, and the composer's glass, which
    /// samples the transcript behind it, magnifies that into a picture that is different by
    /// more than a shade. These fit, so nothing scrolls and nothing is decided.
    static let fitting: [Turn] = make([
        (.person, "What's on today?"),
        (.assistant, "The dentist at 11, and Krista wanted to talk about the garden when you're back."),
        (.person, "Thanks."),
    ])

    static let long: [Turn] = make([
        (.person, "Morning. What's on today?"),
        (.assistant, "Two things: the dentist at 11, and Krista wanted to talk about the garden when you're back. Nothing else on the calendar."),
        (.person, "Remind me to pick up Daphne's food on the way home."),
        (.assistant, "Done. It'll pop up when you leave the dentist."),
        (.person, "Can you explain, briefly, why the sky is blue but sunsets are red? I keep forgetting."),
        (.assistant, "Air scatters short wavelengths more than long ones, so blue light bounces around the whole sky. At sunset the light crosses far more air on its way to you, and by then most of the blue has scattered away, leaving the reds and oranges that travel straighter."),
        (.person, "ta"),
        (.assistant, "Any time."),
    ])

    private static func make(_ lines: [(TurnRole, String)]) -> [Turn] {
        var turns: [Turn] = []
        var previous: TurnRef?
        for (index, (role, text)) in lines.enumerated() {
            let ref = TurnRef(device: role == .person ? phone : hub, sequence: Int64(index + 1))
            let at = Date(timeIntervalSinceNow: Double(index - lines.count) * 90)
            turns.append(Turn(ref: ref, parents: previous.map { [$0] } ?? [], role: role, text: text, at: at))
            previous = ref
        }
        return turns
    }
}

#if os(iOS)
/// The chat as one view, with nothing behind it: the transcript, the row at the end of it, the
/// badge in the bar and the glass under it, all drawn from the environment's look and from the
/// fixtures above. It is what the canvas shows and what the render suite photographs, so the
/// screen a look is judged on is one view and not two ideas of it.
struct ChatCanvas: View {
    var turns: [Turn] = PreviewTurns.long
    /// Whether this canvas is one that will be compared with another, which is what makes a
    /// scrolled transcript a problem rather than a detail — see `PreviewTurns.fitting`.
    var notice: String?
    var mic: Composer.MicState = .init()
    /// What the row at the end of the transcript is doing.
    var row: Row = .hidden

    enum Row: String, CaseIterable { case hidden, writing, inFlight }

    var body: some View {
        NavigationStack {
            TranscriptView(turns: turns, notice: notice,
                           replay: Replay(canSpeak: true),
                           actions: TurnActions(edit: { _ in }),
                           draft: draft)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge() } }
                .safeAreaInset(edge: .bottom) {
                    Composer(typing: .constant(false), mic: mic)
                }
        }
    }

    /// The row is drawn from what it is handed, so a state of it is a value here rather than a
    /// screen something has to type into. The keyboard is never asked for: a row with words in it
    /// is shown whether or not anything is focused, which is what a caption from the microphone
    /// looks like.
    private var draft: Draft? {
        guard row != .hidden else { return nil }
        return Draft(text: .constant("Remind me to pick up Daphne's food on the way home"),
                     typing: .constant(false), sending: row == .inFlight, edit: {})
    }
}
#endif

// One preview per platform, each in the target that can draw it: a preview is rendered by the
// build it is compiled into, so the watch's and the television's are theirs and not the phone's
// idea of them.
#if os(iOS)
#Preview("Transcript") {
    @Previewable @State var turnCount = 8
    @Previewable @State var notice = false
    @Previewable @State var speaking = false

    VStack(spacing: 0) {
        TranscriptView(turns: Array(PreviewTurns.long.prefix(turnCount)),
                       notice: notice ? "Topo is on another device; this one shows what it says." : nil,
                       replay: Replay(speaking: speaking, canSpeak: true),
                       actions: TurnActions(edit: { _ in }))
        Divider()
        VStack(alignment: .leading) {
            Stepper("Turns: \(turnCount)", value: $turnCount, in: 0...PreviewTurns.long.count)
            Toggle("Notice", isOn: $notice)
            Toggle("Speaking", isOn: $speaking)
        }
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
    }
}
#endif

#if os(watchOS)
#Preview("Transcript") {
    TranscriptView(turns: Array(PreviewTurns.long.suffix(4)))
}
#endif

#if os(tvOS)
#Preview("Transcript") {
    TranscriptView(turns: PreviewTurns.long)
}
#endif
#endif
