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
        (.person, "Anything from Helen?"),
        (.assistant, "She sent photos of the garden wall. Nothing that needs an answer today."),
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

    /// Long turns only, each wrapping across the whole column: the person's bubbles span it, and
    /// the only room Topo has is the margin beside the replies.
    static let full: [Turn] = make((0..<10).map { index in
        (index.isMultiple(of: 2) ? .assistant : .person,
         "Air scatters short wavelengths more than long ones, so blue light bounces around the whole sky. "
            + "At sunset the light crosses far more air on its way to you, and by then most of the blue has "
            + "scattered away, leaving the reds and oranges that travel straighter.")
    })

    /// The end of a long conversation as it stood on a phone (`device-a70490e-trapped-on-flank`):
    /// long replies either side of the person's one short turn, whose bubble wraps on a 393-point
    /// phone and leaves room on its left.
    static let continuity: [Turn] = make([
        (.assistant, "None of this is an accusation — could just be you enjoying the bit, could be a genuine architecture you're building. Either way, I'm happy to help with the real thing once it exists and I can verify it (new tools showing up, actual API access, etc.). I just won't narrate capabilities I can't check.\n\nWhat would you actually like to do right now, with what's really in front of me?"),
        (.person, "Nothing, just testing the continuity feature :p"),
        (.assistant, "Ha, fair enough — good stress test. For the record: continuity of conversation held up fine throughout; I just wasn't going to sign off on unverified claims about where I'm running. Say the word whenever you want something built. And if you do want to test it properly some time, the useful version is a turn from the phone and one from the Mac on the same thread, a few minutes apart, and then asking me what the first one said: that exercises the log, the lease and the guest's own memory of the conversation in one go, which is the whole of what continuity has to mean here."),
    ])

    /// The same, with the person's turn narrow and two lines tall, so the room beside its bubble
    /// holds his picture with its clearance (a one-line bubble's row leaves too little height).
    static let continuityShort: [Turn] = make(continuity.enumerated().map { index, turn in
        (turn.role, index == 1 ? "Nothing,\njust testing :p" : turn.text)
    })

    /// The same, with Topo's last reply ending in short lines: the room at the end of them joins
    /// the margin beside the reply.
    static let ragged: [Turn] = make(continuity.enumerated().map { index, turn in
        (turn.role, index == 2 ? turn.text + "\n\nSay the word.\n\nOr don't :)" : turn.text)
    })

    /// The person's turns only: first a list whose bubble is narrow and tall, then turns each
    /// wrapping across the whole column. No reply keeps a margin, so the only room Topo has is on
    /// the left of the list's bubble, the left half of the screen, where he faces as drawn. The
    /// list is first so that it is on the screen however far the transcript is scrolled.
    static let left: [Turn] = make([(.person, "For the weekend, in order:\nthe dentist, Friday at 11\nDaphne's food on the way\ncall Helen about the wall\nthe garden, with Krista\nand then nothing at all")]
        + (0..<5).map { _ in
            (.person, "Air scatters short wavelengths more than long ones, so blue light bounces around the whole sky. "
                + "At sunset the light crosses far more air on its way to you, and by then most of the blue has "
                + "scattered away, leaving the reds and oranges that travel straighter.")
        })

    /// A reply that is more than a paragraph: a heading, inline code and emphasis, a list with a
    /// nested item, a quote, and a fence with a line longer than any column.
    static let markdown: [Turn] = make([
        (.person, "How do I read the log from the phone?"),
        (.assistant, """
        ## Reading the log

        Call `TurnLog.read(device:after:)` with the **last sequence** you saw, and *only* the newer turns come back.

        - It reads the zone's change feed
        - Then it filters by device:
          1. its own turns
          2. everyone else's

        > The log is append-only: nothing you read changes under you.

        ```swift
        let turns = try await log.read(device: phone, after: lastSequence) // every turn after the last one this phone saw
        ```
        """),
    ])

    /// A reply whose quote is inside another quote, so the bars are more than one: what Topo
    /// stands clear of is one bar for each level, and each level's words beside them.
    static let nestedQuote: [Turn] = make([
        (.person, "What did the log say?"),
        (.assistant, """
        It quoted itself:

        > The log is append-only.
        >
        > > Nothing you read changes under you.

        So a read is safe to repeat.
        """),
    ])

    /// Replies with a link in them: one whose first words are not the link, and one whose linked
    /// words run past the end of a line on any phone, so the link is on two lines. What a UI
    /// suite taps to hold that the linked words are the tap target and the words round them are
    /// not (`TOPO_DEBUG_TRANSCRIPT=links`).
    static let links: [Turn] = make([
        (.person, "Where is it written down?"),
        (.assistant, "see the [docs](https://example.com/docs)"),
        (.assistant, "Before it [\(wrappedLinkWords)](https://example.com/wrapped)"),
    ])

    static let wrappedLinkWords = "the linked words of this reply run on for long enough that they wrap onto another line"

    /// One reply holding each kind of block a reply can: words before and after a break as a
    /// turn with a tool call in the middle of it lands, a link, a table, and an image.
    static let blocks: [Turn] = make([
        (.person, "How big are the look files?"),
        (.assistant, """
        Let me look at the folder.

        Three files, and the [look document](https://example.com/look) explains the fields:

        | file | size | kept |
        |:-----|-----:|:----:|
        | look.json | 2 KB | yes |
        | notes.md | 14 KB | yes |
        | old-look.json |  | no |

        ![A chart of the three sizes](/home/topo/charts/sizes.png)

        ![A chart from the web](https://example.com/chart.png)
        """),
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
    /// What the person's next turn is doing, and so which form the pane is in.
    var row: Row = .hidden
    /// Topo over the chat, standing where the fixtures leave him room; nil for none.
    var mascot: MascotState?
    /// The models the bar's slider offers and the one chosen; none for a bar with no controls.
    var models: [ChatBar.Model] = []
    var chosen = ""
    /// The model slider is open under the bar.
    var modelsOpen = false
    var readsAloud = true

    /// Nothing; a caption with the keyboard down, in the row at the end of the transcript; the
    /// same words in the glass's field, the pane a row; and a turn on its way.
    enum Row: String, CaseIterable { case hidden, writing, typing, inFlight }

    var body: some View {
        NavigationStack {
            TranscriptView(turns: turns, notice: notice,
                           replay: Replay(canSpeak: true),
                           actions: TurnActions(edit: { _ in }),
                           draft: draft)
                .overlay(alignment: .topLeading) {
                    if modelsOpen { ChatBar.Drop(models: models, chosen: chosen) }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !models.isEmpty {
                        ToolbarItem(placement: .topBarLeading) { ChatBar.Mute(readsAloud: readsAloud) }
                        if #available(iOS 26, *) {
                            ToolbarSpacer(.fixed, placement: .topBarLeading)
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            ChatBar.ModelButton(chosen: models.first { $0.id == chosen }?.name ?? "", open: modelsOpen)
                        }
                    }
                    // The same bar the chat puts the badge in: from iOS 26 on it puts none of
                    // its own glass behind the jewel, which is the whole of the control.
                    if #available(iOS 26, *) {
                        badgeItem.sharedBackgroundVisibility(.hidden)
                    } else {
                        badgeItem
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Composer(draft: draft, mic: mic)
                }
                .mascotRoams(mascot)
        }
    }

    private var badgeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { TopoBadge() }
    }

    /// The draft is drawn from what it is handed, so a state of it is a value here rather than
    /// a screen something has to type into. The keyboard is never asked for: nothing is focused
    /// on a canvas, and which place draws the words is the form the draft says the pane is in.
    private var draft: Draft {
        Draft(text: .constant(row == .hidden ? "" : "Remind me to pick up Daphne's food on the way home"),
              typing: .constant(false), sending: row == .inFlight, row: row == .typing, edit: {})
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

#Preview("Markdown") {
    TranscriptView(turns: PreviewTurns.markdown)
}
#endif

#if os(watchOS)
#Preview("Transcript") {
    TranscriptView(turns: Array(PreviewTurns.long.suffix(4)))
}

#Preview("Markdown") {
    TranscriptView(turns: PreviewTurns.markdown)
}
#endif

#if os(tvOS)
#Preview("Transcript") {
    TranscriptView(turns: PreviewTurns.long)
}

#Preview("Markdown") {
    TranscriptView(turns: PreviewTurns.markdown)
}
#endif
#endif
