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
    /// The person's next turn, drawn at the end of the transcript while the glass under it has
    /// no field for it, so it wraps as the turn it is about to become. Nil on a screen with
    /// nothing to write with — the watch, the television, a viewer — and the row is then never
    /// drawn.
    var draft: Draft?
    /// Turns on their way that the row is not holding: said before its own, and said after it.
    /// Each is drawn in the draft's sending colour until the log has it and it is a turn.
    var queued: (before: [QueuedTurn], after: [QueuedTurn]) = ([], [])
    /// The guest's reply to the turn the row holds, as far as it is written, while that turn is
    /// not in the log: drawn under the row, as the reply to a queued turn is under its words.
    var answer: Turn?
    /// The code block the voice has just reached (`Speaker.cue`): scrolled into view, and drawn
    /// pulsing by the reply it is in. Nil on a screen with no voice.
    var cue: CodeBlockCue?
    @Environment(\.look) private var look
    /// The turns whose rows the lazy stack has made, which a code block can be scrolled to by its
    /// own place, and the block waiting on its row to be made; a reference, so a row coming and
    /// going redraws nothing.
    @State private var made = MadeRows()
    /// How tall the scroll view is, which is how far past the last turn a tap still lowers the
    /// keyboard.
    @State private var height: CGFloat = 0

    final class MadeRows {
        var turns: Set<TurnRef> = []
        var pending: CodeBlockCue.Place?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The draft's row is outside the lazy stack, so it is always made: over a
                // transcript taller than the screen, a row inside a lazy stack scrolled to it
                // loads, grows the stack, is scrolled out, unloads and shrinks it again inside
                // one layout pass, which never ends and freezes the app.
                VStack(alignment: .leading, spacing: look.transcript.spacing) {
                    LazyVStack(alignment: .leading, spacing: look.transcript.spacing) {
                        if let notice {
                            Text(notice)
                                .font(look.transcript.noticeFont)
                                .foregroundStyle(look.transcript.caption)
                                .mascotObstacle()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(turns) { turn in
                            TurnRow(turn: turn, replay: replay, actions: actions,
                                    cue: cue?.reply == turn.ref ? cue : nil).id(turn.ref)
                                .onAppear { made.turns.insert(turn.ref) }
                                .onDisappear { made.turns.remove(turn.ref) }
                        }
                    }
                    ForEach(queued.before) { queued($0) }
                    if let draft, draft.drawer == .row {
                        DraftRow(draft: draft).id(Self.draftID)
                    }
                    if let answer { TurnRow(turn: answer, replay: replay, actions: actions).id(answer.ref) }
                    ForEach(queued.after) { queued($0) }
                }
                .padding(.horizontal, look.transcript.horizontalPadding)
                .padding(.vertical, look.transcript.spacing)
                .frame(maxWidth: look.transcript.maximumLineWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                #if os(iOS)
                .background(alignment: .top) { lowering }
                #endif
            }
            #if os(iOS)
            // A drag down the transcript takes the keyboard down with the finger.
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            #endif
            // Where Topo may stand, on a screen that draws him: the frame the turns scroll in.
            .mascotVisible()
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: turns.last?.ref) { _, _ in scroll(proxy, animated: true) }
            // The row appearing, and each line it grows by, keep it where the newest turn was.
            .onChange(of: draft?.drawer) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: draft?.text) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: queued.before.last?.id) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: queued.after.last?.id) { _, _ in scroll(proxy, animated: true) }
            // A reply the guest wrote ahead of iCloud arrives under words already drawn.
            .onChange(of: end) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: unsavedWords) { _, _ in scroll(proxy, animated: true) }
            // A block the voice reaches is brought into view, by as little as shows it whole: one
            // already on the screen does not move. A block inside a row the lazy stack has not
            // made has no place to be scrolled to yet, so its row is brought in first, and the
            // block once it says it has been made — however tall the row, and wherever in it.
            .onChange(of: cue?.serial) { _, _ in
                guard let cue else { return }
                guard made.turns.contains(cue.reply) else {
                    made.pending = cue.place
                    proxy.scrollTo(cue.reply, anchor: nil)
                    return
                }
                made.pending = nil
                withAnimation { proxy.scrollTo(cue.place, anchor: nil) }
            }
            .environment(\.codeBlockAppeared) { place in
                guard made.pending == place else { return }
                made.pending = nil
                // Made in this pass, laid out by the next. Not animated: the stack is still measuring
                // the rows around it, and a re-layout during an animated scroll puts the transcript
                // back where the scroll to the row left it, with the block off the screen again.
                DispatchQueue.main.async { proxy.scrollTo(place, anchor: nil) }
            }
        }
    }

    /// The row being written, as the transcript scrolls to it.
    static let draftID = "draft"

    #if os(iOS)
    /// A tap on the transcript's own empty space puts the keyboard down. It is a view behind the
    /// turns and not a gesture on them, so a turn's words, its links and its held menu are no
    /// part of it: a tap that lands on any of them never reaches what is behind. It runs the
    /// scroll view's height past the last turn, which is the empty space a short chat has most
    /// of, without the content being any taller for it.
    @ViewBuilder private var lowering: some View {
        if let draft {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { draft.typing = false }
                .padding(.bottom, -height)
                .accessibilityHidden(true)
        }
    }
    #endif

    /// What the transcript scrolls to: whatever is drawn last. That is a turn on its way said
    /// after the row's, or the guest's reply to it; then the reply to the row's own words, then
    /// the row while it is shown, then a turn on its way said before it or its reply, then the
    /// newest turn — so a caption arriving with no keyboard is scrolled to like anything else,
    /// and neither a turn still owed below the row nor a reply the log does not hold yet is left
    /// under the fold.
    var end: AnyHashable? {
        if let last = queued.after.last { return Self.end(of: last) }
        if let answer { return AnyHashable(answer.ref) }
        if draft?.drawer == .row { return AnyHashable(Self.draftID) }
        if let last = queued.before.last { return Self.end(of: last) }
        return turns.last.map { AnyHashable($0.ref) }
    }

    /// The words of every reply drawn below the log's turns, top to bottom: each grows as the
    /// guest writes it and moves whatever is drawn under it, so the transcript follows its end
    /// down on a change to any of them.
    var unsavedWords: [String] {
        queued.before.compactMap { $0.reply?.text } + (answer.map { [$0.text] } ?? []) + queued.after.compactMap { $0.reply?.text }
    }

    private static func end(of turn: QueuedTurn) -> AnyHashable {
        turn.reply.map { AnyHashable($0.ref) } ?? AnyHashable(turn.id)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let end else { return }
        if animated {
            withAnimation { proxy.scrollTo(end, anchor: .bottom) }
        } else {
            proxy.scrollTo(end, anchor: .bottom)
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
    /// The code block of this turn the voice has reached, if any.
    var cue: CodeBlockCue?
    @Environment(\.look) private var look

    private var mine: Bool { turn.role == .person }

    /// What the words are drawn on. The view chooses the side and the look chooses everything
    /// drawn on it, Topo's side included, which is why there is no number here.
    private var enclosure: Look.Enclosure { mine ? look.bubble : look.plain }

    /// Nothing is drawn around the words, so what Topo stands clear of is the words themselves.
    private var bare: Bool { enclosure.drawsNothing }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: look.transcript.captionSpacing) {
            words
                .padding(.horizontal, enclosure.horizontalPadding)
                .padding(.vertical, enclosure.verticalPadding)
                .background { TurnShape.fill(enclosure) }
            Text(turn.at, format: .dateTime.hour().minute())
                .font(look.transcript.labelFont)
                .foregroundStyle(look.transcript.caption)
                .padding(.horizontal, enclosure.horizontalPadding)
                .mascotObstacle(bare)
        }
        // An enclosed turn is its enclosure and the time as drawn, before the row takes the
        // column's width: Topo stands clear of them, and beside a short bubble is room for him.
        .mascotObstacle(!bare)
        // Topo's turns keep a margin on their trailing side, which is where he stands beside
        // them, and the person's the same on their leading side, so both are indented alike.
        .padding(.trailing, mine ? .zero : look.transcript.replyTrailingInset)
        .padding(.leading, mine ? look.transcript.personLeadingInset : .zero)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        #if os(iOS)
        // Held, never tapped: a turn brushed in passing must not start talking. What is offered
        // is `TurnMenu`'s to say, so which items a turn gets is a value a test can read rather
        // than a gesture nothing can press.
        .contextMenu {
            ForEach(TurnMenu.items(for: turn, replay: replay, actions: actions,
                                   copy: { UIPasteboard.general.string = $0 })) { item in
                Button { item.act() } label: { Label(item.title, systemImage: item.systemImage) }
            }
        }
        #endif
        #if os(tvOS)
        // The remote scrolls a tvOS list by moving focus, so every turn has
        // to be somewhere focus can land.
        .focusable()
        #endif
    }

    /// Topo's words are markdown, drawn as their blocks. The person's are drawn as they were
    /// typed: the row they are written in is drawn at the size the landed turn will be, which a
    /// turn restyled on landing would not be, and what they typed is theirs to see as typed.
    /// Words with nothing drawn around them report their lines, so the room at the end of a
    /// short line is room for Topo.
    @ViewBuilder
    private var words: some View {
        if mine {
            Text(turn.text)
                .font(look.transcript.bodyFont)
                .foregroundStyle(look.transcript.text)
                .fixedSize(horizontal: false, vertical: true)
                .mascotLines(bare)
        } else {
            MarkdownText(source: turn.text, bare: bare, reply: turn.ref, cue: cue)
        }
    }
}

extension TranscriptView {
    /// A turn on its way, and under it the guest's reply when it has one the log does not.
    @ViewBuilder fileprivate func queued(_ turn: QueuedTurn) -> some View {
        QueuedTurnRow(turn: turn).id(turn.id)
        if let reply = turn.reply { TurnRow(turn: reply, replay: replay, actions: actions).id(reply.ref) }
    }
}

/// Words on the line that are not in the log and not in the row: a turn on its way that nothing
/// else draws.
struct QueuedTurn: Identifiable, Equatable {
    let text: String
    let nonce: String
    /// The guest's reply to these words, written before iCloud took the turn: no turn of the
    /// log's, drawn under the words until the log has both.
    var reply: Turn?
    var id: String { nonce }
}

/// A turn on its way that the row is not holding, drawn where the person's turn will land and in
/// the colour the row draws a turn on its way in (`look.draft.sending`): it is not a turn until the
/// log has it, and then it is drawn as one, in the person's own bubble.
struct QueuedTurnRow: View {
    let turn: QueuedTurn
    @Environment(\.look) private var look

    var body: some View {
        let enclosure = look.draft.sending
        Text(turn.text)
            .font(look.transcript.bodyFont)
            .foregroundStyle(look.transcript.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, enclosure.horizontalPadding)
            .padding(.vertical, enclosure.verticalPadding)
            .background { TurnShape.fill(enclosure) }
            .mascotObstacle()
            .padding(.leading, look.transcript.personLeadingInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityValue("Sending")
    }
}

/// What holding a turn offers, as values rather than as a block of buttons inside a view: a
/// context menu is a gesture no test can press, so which items each role gets is decided here and
/// read there.
///
/// Topo's turns offer saying them again — or stopping, while something is being said — and copy;
/// the person's own offer edit, where there is a row to put the words back into, and copy. A
/// person's own words are not Topo's to say, which is `Replay`'s answer and not this one's.
enum TurnMenu {
    /// One item: what it reads, the mark beside it, and what it does.
    struct Item: Identifiable {
        let title: String
        let systemImage: String
        let act: @MainActor () -> Void

        var id: String { title }
    }

    /// Where Copy's text goes is handed in rather than reached for, so the items can be read
    /// without a pasteboard behind them.
    static func items(for turn: Turn, replay: Replay = Replay(), actions: TurnActions = TurnActions(),
                      copy: @escaping @MainActor (String) -> Void) -> [Item] {
        var items: [Item] = []
        if let offer = replay.offer(for: turn) {
            items.append(Item(title: offer.title, systemImage: offer.systemImage, act: offer.act))
        }
        if turn.role == .person, let edit = actions.edit {
            items.append(Item(title: "Edit", systemImage: "pencil", act: { edit(turn) }))
        }
        let text = turn.text
        items.append(Item(title: "Copy", systemImage: "doc.on.doc", act: { copy(text) }))
        return items
    }
}

/// What a turn's words sit on, drawn entirely from the look: a tint under an outline, over one
/// of the system's backdrops or over nothing. The person's enclosure draws a bubble; Topo's is
/// the same shape with no outline, no tint and no backdrop, so it draws nothing at all.
enum TurnShape {
    @ViewBuilder
    static func fill(_ look: Look.Enclosure) -> some View {
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

/// The person's next turn, before it is one: what is written, what has become of it, and which
/// of the two places that can draw it does. The field in the glass and the row at the end of
/// the transcript are both drawn from this and nothing else, so each state is a value a test can
/// make rather than a screen a test has to photograph.
struct Draft {
    /// What is written. Bound, because the field is where it is typed and a caption from the
    /// microphone is written into it.
    @Binding var text: String
    /// The keyboard is asked for. Bound both ways: the control that raises the keyboard sets it,
    /// a tap on the row does, and the keyboard going down clears it.
    @Binding var typing: Bool
    /// The turn is said and on its way, and not yet in the log.
    var sending = false
    /// The pane under the transcript is a row, so its field has what is written
    /// (`ComposerForm`).
    var row = false
    /// Sends what is written.
    var send: @MainActor () -> Void = {}
    /// Takes the turn on its way back, so its words can be changed and said once. Nil while
    /// there is nothing to take back — nothing on its way, an attempt in flight that may be
    /// landing as it is asked, or a turn already known to be in the log.
    var edit: (@MainActor () -> Void)?

    /// The three states of the draft.
    enum State: String, Equatable, Sendable {
        /// Nothing written and no keyboard asked for.
        case hidden
        /// Being written, or holding what the microphone has heard so far.
        case writing
        /// Said, and not yet in the log.
        case inFlight
    }

    var state: State {
        if sending { return .inFlight }
        return typing || !text.isEmpty ? .writing : .hidden
    }

    /// Where what is written is drawn, which is in one place or none.
    enum Drawer: String, Equatable, Sendable {
        case none
        /// The field in the glass.
        case pane
        /// The row at the end of the transcript.
        case row
    }

    /// A turn on its way is the row's, whatever form the pane is in: the field is closed to it.
    /// What is being written is the field's while the pane is a row, and the row's otherwise,
    /// where there is anything to draw: a caption the microphone is writing with the keyboard
    /// down.
    var drawer: Drawer {
        switch state {
        case .hidden: .none
        case .inFlight: .row
        case .writing: row ? .pane : text.isEmpty ? .none : .row
        }
    }
}

/// The person's next turn at the end of the transcript, while the glass has no field for it: a
/// caption the microphone is writing with the keyboard down, and the turn on its way. It is
/// drawn at the size the turn will be — the same type, the same width for the same words, an
/// enclosure of the same shape — so nothing moves when it lands. What it is not yet is a turn,
/// and the colour says so: it is drawn in `look.draft.written` while it is being written and in
/// `look.draft.sending` while it is on its way, and becomes the person's own `look.bubble` by
/// landing in the log.
///
/// It is words and no field. A tap on what is being written raises the keyboard, and the words
/// are then the glass's field's. A spinner beside a turn on its way says so a second way, and
/// holding the row is the way back from that: it takes the words out of the outbox and puts them
/// back to be changed, so what is said again is one turn and not two.
struct DraftRow: View {
    var draft: Draft
    @Environment(\.look) private var look

    var body: some View {
        // Indented as the person's turn it is about to become, so it wraps where that will, as
        // far as leaves the bubble its minimum width and the spinner its slot.
        DraftInset(inset: look.transcript.personLeadingInset, keep: Self.kept(look.draft)) {
            HStack(alignment: .bottom, spacing: look.draft.spacing) {
                bubble
                spinner
            }
            .mascotObstacle()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// What the row keeps of its width whatever the person's inset: the bubble at its minimum,
    /// the room beside it and the spinner's slot.
    static func kept(_ draft: Look.Draft) -> CGFloat {
        draft.minimumWidth + draft.spacing + draft.slot
    }

    /// The person's inset as the row takes it in `width`: all of it where it leaves `kept`, and
    /// only as much as does where it would not, so the inset yields and the spinner stays in
    /// the column.
    static func inset(_ inset: CGFloat, keeping kept: CGFloat, in width: CGFloat) -> CGFloat {
        guard inset.isFinite, width.isFinite else { return 0 }
        return min(max(inset, 0), max(width - kept, 0))
    }

    /// What the words are drawn on: the draft's own enclosure, in the colour of the state it is
    /// in. The view picks between two values the look names rather than changing one of them, so
    /// a look that wants a draft drawn differently in either state says so there.
    private var enclosure: Look.Enclosure {
        draft.sending ? look.draft.sending : look.draft.written
    }

    /// What the UI suites find the row's words by.
    static let identifier = "draft-row"

    /// The words, hugged by the bubble and broken where the landed turn will break them: in the
    /// width the row has, which is the transcript's less the slot beside it.
    private var bubble: some View {
        Text(draft.text)
            .font(look.transcript.bodyFont)
            .foregroundStyle(look.transcript.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, enclosure.horizontalPadding)
            .padding(.vertical, enclosure.verticalPadding)
            .background { TurnShape.fill(enclosure) }
            .accessibilityIdentifier(Self.identifier)
            #if os(iOS)
            .contextMenu {
                if let edit = draft.edit {
                    Button { edit() } label: { Label("Edit", systemImage: "pencil") }
                }
            }
            // What is being written goes on being written in the glass; a turn on its way is
            // not to be typed into.
            .onTapGesture { if draft.state != .inFlight { draft.typing = true } }
            #endif
    }

    /// One slot beside the bubble at every state, so the row does not move when the turn goes.
    private var spinner: some View {
        Color.clear
            .frame(width: look.draft.slot, height: look.draft.slot)
            .overlay {
                if draft.state == .inFlight {
                    ProgressView()
                        .tint(look.draft.sendInk)
                        .accessibilityLabel("Sending")
                }
            }
    }
}

/// The draft row's leading inset, taken out of the width it is offered as far as leaves `keep`
/// of it: one pass of layout, so the row is laid out at its inset from the frame it appears in.
struct DraftInset: Layout {
    var inset: CGFloat
    var keep: CGFloat

    private func taken(_ proposal: ProposedViewSize) -> CGFloat {
        proposal.width.map { DraftRow.inset(inset, keeping: keep, in: $0) } ?? max(inset, 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let inset = taken(proposal)
        let size = row.sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0 - inset, 0) },
                                                     height: proposal.height))
        return CGSize(width: size.width + inset, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let inset = taken(proposal)
        row.place(at: CGPoint(x: bounds.minX + inset, y: bounds.minY), anchor: .topLeading,
                  proposal: ProposedViewSize(width: max(bounds.width - inset, 0), height: bounds.height))
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
    /// Says a turn again; the turn rather than its words, so what the voice reaches in it is
    /// shown on it (`CodeBlockCue`).
    var say: @MainActor (Turn) -> Void = { _ in }
    var stopSpeaking: @MainActor () -> Void = {}

    /// What holding `turn` offers, or nothing at all. A person's own turn offers nothing: their
    /// words are not Topo's to say.
    func offer(for turn: Turn) -> Offer? {
        guard canSpeak, turn.role == .assistant else { return nil }
        if speaking {
            return Offer(title: "Stop", systemImage: "stop.fill", act: stopSpeaking)
        }
        return Offer(title: "Say again", systemImage: "speaker.wave.2", act: { say(turn) })
    }

    /// One menu item: what it reads and what it does.
    struct Offer {
        let title: String
        let systemImage: String
        let act: @MainActor () -> Void
    }
}
