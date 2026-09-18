import SwiftUI
import TopoCore

/// The transcript, read-only, on whatever screen it is given. The phone, the
/// watch and the TV all show the same turns in the same order; what changes
/// between them is the type size and how far the turns are from the edges.
struct TranscriptView: View {
    let turns: [Turn]
    var notice: String?
    /// What holding a turn offers. The default offers nothing, which is what a screen with no
    /// voice behind it — the watch, the television, a viewer — shows.
    var replay = Replay()
    /// What holding one of the person's own turns offers. The default offers copy alone.
    var actions = TurnActions()
    /// The person's next turn while it is being written: a bubble at the end of the transcript
    /// with the field in it. Nil on a screen that cannot compose.
    var draft: Draft?
    /// Where a turn on the person's side came from when it was not the person: a timed alert,
    /// another agent. Named turns land as their bubbles, in the secondary colour, with the name
    /// over the bubble. The default names none.
    var origin: (Turn) -> String? = { _ in nil }
    /// A question at the head of the log with its answers to pick from, above the draft.
    var question: Question?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacing) {
                    if let notice {
                        Text(notice)
                            .font(Metrics.noticeFont)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn, replay: replay, actions: actions, origin: origin(turn)).id(turn.ref)
                    }
                    if let question {
                        QuestionView(question: question).id("question")
                    }
                    if let draft, draft.shown {
                        DraftRow(draft: draft).id("draft")
                    }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, Metrics.spacing)
                .frame(maxWidth: Metrics.maximumLineWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: turns.last?.ref) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: draft?.shown ?? false) { _, shown in
                if shown { withAnimation { proxy.scrollTo("draft", anchor: .bottom) } }
            }
        }
    }

    /// The newest turn is the one worth seeing, so the transcript opens at
    /// the end and follows it.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = turns.last?.ref else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

/// One turn: the person's in a bubble on the right, Topo's as plain text on the left. Injected
/// content — a timed alert, another agent's message — sits on the person's side too, in the
/// secondary colour with its origin named above the bubble.
struct TurnRow: View {
    let turn: Turn
    var replay = Replay()
    var actions = TurnActions()
    var origin: String?

    private var mine: Bool { turn.role == .person }
    private var accent: Color { origin == nil ? Theme.primary : Theme.secondary }
    /// An injected turn is folded to its origin and time until tapped; a spoken or typed turn
    /// is never folded.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if let origin {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        // Folded, the line carries the time; unfolded, the time moves under
                        // the bubble where every turn's is.
                        if expanded {
                            Text(origin)
                        } else {
                            Text("\(origin), \(turn.at, format: .dateTime.hour().minute())")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(Metrics.labelFont)
                    .foregroundStyle(accent)
                    .padding(.horizontal, Metrics.bubblePadding)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(origin), \(expanded ? "collapse" : "expand")")
            }
            if origin == nil || expanded {
                Text(turn.text)
                    .font(Metrics.bodyFont)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, mine ? Metrics.bubblePadding : 0)
                    .padding(.vertical, mine ? Metrics.bubblePadding * 0.7 : 0)
                    .background(mine ? Bubble.fill(accent) : nil)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if origin == nil || expanded {
                Text(turn.at, format: .dateTime.hour().minute())
                    .font(Metrics.labelFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, mine ? Metrics.bubblePadding : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .clipped()
        #if os(iOS)
        // Held, never tapped: a turn brushed in passing must not start talking. Topo's turns
        // offer saying it again (or stopping) and copy; the person's offer edit, undo and copy.
        .contextMenu {
            if let offer = replay.offer(for: turn) {
                Button { offer.act() } label: { Label(offer.title, systemImage: offer.systemImage) }
            }
            if mine, let edit = actions.edit {
                Button { edit(turn) } label: { Label("Edit", systemImage: "pencil") }
            }
            if mine, let undo = actions.undo {
                Button(role: .destructive) { undo(turn) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
            Button { UIPasteboard.general.string = turn.text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        #endif
        #if os(tvOS)
        // The remote scrolls a tvOS list by moving focus, so every turn has
        // to be somewhere focus can land.
        .focusable()
        #endif
    }
}

/// The person's bubble: an outline in the colour of the controls it came from, over a faint
/// tint of the same, so it reads as the turn the glass sent rather than a block of colour.
enum Bubble {
    static func fill(_ accent: Color = Theme.primary) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return shape.fill(accent.opacity(0.12))
            .overlay(shape.strokeBorder(accent, lineWidth: 1.5))
    }
}

/// The person's next turn in progress: typed, or the live caption of what the microphone hears.
struct Draft {
    var text: Binding<String>
    /// The keyboard is wanted. The row shows while this is on or while there is text, so a
    /// caption shows with no keyboard and a field stays until it is dismissed.
    var active: Binding<Bool>
    /// Sent and not yet in the log: the bubble holds its words in the signal colour and the
    /// send button is a spinner, until the turn lands and the row goes.
    var sending = false
    var send: () -> Void

    var shown: Bool { active.wrappedValue || !text.wrappedValue.isEmpty }
    var hasText: Bool { !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The bubble the person is writing into, at the end of the transcript, with send beside it.
/// Secondary while it is being written, signal while it is on its way; it becomes a primary
/// bubble only by landing in the log as a turn.
struct DraftRow: View {
    let draft: Draft
    @FocusState private var focused: Bool

    private var accent: Color { draft.sending ? Theme.signal : Theme.secondary }
    private var empty: Bool { draft.text.wrappedValue.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // The bubble is sized by the text as the transcript will set it, wrapping at the
            // same width; the field lies over that text and never sets a size of its own, so
            // the bubble is the same in every state and never scrolls.
            Text(draft.text.wrappedValue.isEmpty ? " " : draft.text.wrappedValue + " ")
                .font(Metrics.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .overlay(alignment: .topLeading) {
                    TextField("", text: draft.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Metrics.bodyFont)
                        .foregroundStyle(Theme.text)
                        .tint(accent)
                        .disabled(draft.sending)
                        .focused($focused)
                        .onSubmit(draft.send)
                }
                .padding(.horizontal, Metrics.bubblePadding)
                .padding(.vertical, Metrics.bubblePadding * 0.7)
                .background(Bubble.fill(accent))
                // Empty, the caret waits at the right where the words will end up.
                .frame(minWidth: 160, alignment: empty ? .trailing : .leading)
            // One slot, one size, whichever of the two is in it.
            ZStack {
                if draft.sending {
                    ProgressView().tint(Theme.secondary)
                } else {
                    Button(action: draft.send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!draft.hasText)
                    .opacity(draft.hasText ? 1 : 0.35)
                    .accessibilityLabel("Send")
                }
            }
            .frame(width: 36, height: 36)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: draft.sending)
        .onAppear { focused = draft.active.wrappedValue }
        .onChange(of: draft.active.wrappedValue) { _, active in focused = active }
        .onChange(of: focused) { _, focused in if !focused { draft.active.wrappedValue = false } }
    }
}

/// What holding one of the person's own turns offers beyond copy. Each is nil where the screen
/// has nothing behind it, and the item is then not shown.
struct TurnActions {
    /// The turn's words go back into the draft to be changed and sent again.
    var edit: (@MainActor (Turn) -> Void)?
    /// The turn is taken back. The log is append-only, so this is a turn of its own that says
    /// so, not a deletion.
    var undo: (@MainActor (Turn) -> Void)?
}

/// Saying a turn again on demand. Only a spoken turn's reply is read aloud as it arrives, so a
/// typed turn's reply is silent; holding it is how it gets heard. The speaker belongs to the
/// chat screen and is threaded down to the rows from there, so nothing here reaches for it.
struct Replay {
    /// True while the speaker is reading something, whichever turn started it: the offer on
    /// every row is then the one that stops it, since two replies over each other is noise.
    var speaking = false
    /// Whether the phone can say anything at all. Speaking is foreground work — iOS suspends a
    /// backgrounded process — so the offer is gone while the scene is not active. Whether the
    /// voice is resident does not come into it: a phone that has not finished downloading Pocket
    /// is offered the item and hears nothing, which the diagnostics `voice` row explains.
    var canSpeak = false
    var say: @MainActor (String) -> Void = { _ in }
    var stopSpeaking: @MainActor () -> Void = {}

    /// What holding `turn` offers, or nothing at all. A person's own turn offers nothing: their
    /// words are not Topo's to say.
    func offer(for turn: Turn) -> Offer? {
        guard canSpeak, turn.role == .assistant else { return nil }
        if speaking {
            return Offer(title: "Stop", systemImage: "stop.fill", act: stopSpeaking)
        }
        return Offer(title: "Say again", systemImage: "speaker.wave.2", act: { say(turn.text) })
    }

    /// One menu item: what it reads and what it does.
    struct Offer {
        let title: String
        let systemImage: String
        let act: @MainActor () -> Void
    }
}

/// What differs between a watch, a phone and a television is the size of the
/// type and how much room the turns get. The transcript itself does not.
enum Metrics {
    #if os(watchOS)
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 2
    static let maximumLineWidth: CGFloat = .infinity
    static let labelFont = Font.system(.caption2).weight(.semibold)
    static let bodyFont = Font.system(.footnote)
    static let noticeFont = Font.system(.caption2)
    static let bubblePadding: CGFloat = 8
    #elseif os(tvOS)
    static let spacing: CGFloat = 24
    static let horizontalPadding: CGFloat = 48
    static let maximumLineWidth: CGFloat = 1100
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.title3)
    static let noticeFont = Font.system(.caption)
    static let bubblePadding: CGFloat = 20
    #else
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let maximumLineWidth: CGFloat = 672
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.body)
    static let noticeFont = Font.system(.caption)
    static let bubblePadding: CGFloat = 14
    #endif
}
