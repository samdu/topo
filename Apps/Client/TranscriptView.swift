import SwiftUI
import TopoCore

/// The transcript, read-only, on whatever screen it is given. The phone, the
/// watch and the TV all show the same turns in the same order; what changes
/// between them is the `Look` each platform defaults to.
struct TranscriptView: View {
    let turns: [Turn]
    var notice: String?
    /// What holding a turn offers. The default offers nothing, which is what a screen with no
    /// voice behind it — the watch, the television, a viewer — shows.
    var replay = Replay()
    /// What holding one of the person's own turns offers beyond copy. The default offers
    /// nothing, which is what a screen with no draft to put the words back into shows.
    var actions = TurnActions()
    @Environment(\.look) private var look

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: look.transcript.spacing) {
                    if let notice {
                        Text(notice)
                            .font(look.transcript.noticeFont)
                            .foregroundStyle(look.transcript.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn, replay: replay, actions: actions).id(turn.ref)
                    }
                }
                .padding(.horizontal, look.transcript.horizontalPadding)
                .padding(.vertical, look.transcript.spacing)
                .frame(maxWidth: look.transcript.maximumLineWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: turns.last?.ref) { _, _ in scroll(proxy, animated: true) }
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

/// One turn: the person's on the right in a bubble, Topo's on the left as plain text. Which side
/// a turn is on and whether it is enclosed is what says who said it; there is no caption over it.
/// The time sits under the words, on the turn's own side.
struct TurnRow: View {
    let turn: Turn
    var replay = Replay()
    var actions = TurnActions()
    @Environment(\.look) private var look

    private var mine: Bool { turn.role == .person }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: look.transcript.captionSpacing) {
            Text(turn.text)
                .font(look.transcript.bodyFont)
                .foregroundStyle(look.transcript.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, mine ? look.bubble.horizontalPadding : 0)
                .padding(.vertical, mine ? look.bubble.verticalPadding : 0)
                .background { if mine { Bubble.fill(look.bubble) } }
            Text(turn.at, format: .dateTime.hour().minute())
                .font(look.transcript.labelFont)
                .foregroundStyle(look.transcript.caption)
                .padding(.horizontal, mine ? look.bubble.horizontalPadding : 0)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        #if os(iOS)
        // Held, never tapped: a turn brushed in passing must not start talking. Topo's turns
        // offer saying them again (or stopping) and copy; the person's own offer edit and copy.
        .contextMenu {
            if let offer = replay.offer(for: turn) {
                Button { offer.act() } label: { Label(offer.title, systemImage: offer.systemImage) }
            }
            if mine, let edit = actions.edit {
                Button { edit(turn) } label: { Label("Edit", systemImage: "pencil") }
            }
            Button { UIPasteboard.general.string = turn.text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        #endif
        #if os(tvOS)
        // The remote scrolls a tvOS list by moving focus, so every turn has
        // to be somewhere focus can land.
        .focusable()
        #endif
    }
}

/// The person's bubble: an outline in their side's colour over a faint tint of the same, so it
/// reads as an enclosure rather than a block of colour. Every value is the look's.
enum Bubble {
    @ViewBuilder
    static func fill(_ look: Look.Bubble) -> some View {
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
        ZStack {
            switch look.surface {
            case .flat: Color.clear
            case .material: shape.fill(.regularMaterial)
            case .glass: shape.fill(.ultraThinMaterial)
            }
            shape.fill(look.accent.opacity(look.fillOpacity))
            shape.strokeBorder(look.accent, lineWidth: look.strokeWidth)
        }
    }
}

/// What holding one of the person's own turns offers beyond copy. Nil where the screen has
/// nothing behind it, and the item is then not shown.
struct TurnActions {
    /// The turn's words go back into the chat's draft, to be changed and said again. The log is
    /// append-only, so this edits what will be said next and never the turn that was.
    var edit: (@MainActor (Turn) -> Void)?
}

/// Saying a turn again on demand. Only a spoken turn's reply is read aloud as it arrives, so a
/// typed turn's reply is silent; holding it is how it gets heard. The speaker belongs to the
/// chat screen and is threaded down to the rows from there, so nothing here reaches for it.
struct Replay {
    /// True while the speaker is reading something, whichever turn started it: the offer on
    /// every row is then the one that stops it, since two replies over each other is noise.
    var speaking = false
    /// Whether the phone can say anything at all: the voice is resident. A phone still
    /// downloading Pocket is offered nothing rather than offered an item it would hear nothing
    /// from, and the diagnostics `voice` row says how far along it is.
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
