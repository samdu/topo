#if os(iOS)
import SwiftUI
import TopoAuth
import TopoCore
import TopoTurn

/// Single-device chat: the transcript from the log, the row at the end of it the next turn is
/// written in, and the glass under it holding the microphone.
struct ChatView: View {
    @Environment(Harness.self) private var harness
    @Environment(SignIn.self) private var signIn
    @Environment(RoleSelector.self) private var roleSelector
    @Environment(Memory.self) private var memory
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""
    @AppStorage("firstRunAnswered") private var answered = false
    @Environment(VoiceInput.self) private var voice
    @Environment(Speaker.self) private var speaker
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Mascot.self) private var mascot
    @AppStorage("readAloud") private var readAloud = true
    /// The model the settings sheet chose, which is the head Topo wears between the guest's turns
    /// (during one, the model the guest reports).
    @AppStorage(Harness.modelKey) private var modelSetting = ClaudeModel.default.rawValue
    /// The row at the end of the transcript: what is written, whether the keyboard has it, and
    /// the turn those words are on their way under. It is a `NextTurn` rather than this screen's
    /// own state because what the row holds outlives the screen — an app killed with words on the
    /// line comes back to the row they were sent from.
    @State private var row = NextTurn()
    /// The row's field holds focus: the pane is present while it does. Not `row.typing`, which
    /// outlives the field while a turn is on its way. It is the presence's and not the pane's
    /// height, because it changes in a transaction of its own ahead of the keyboard, so the
    /// surface fades in on the presence's time where it stands and then rides up with the pane.
    @State private var focused = false
    /// The bottom of the screen's safe area with no keyboard in it, which is what the keyboard's
    /// is measured against (`KeyboardInset`). Nil until it has been measured.
    @State private var restingBottomInset: CGFloat?
    @State private var showSettings = false
    @State private var showDiagnostics = false
    /// The two edges the pane's presence is read from, in the chat's own space: where the
    /// transcript stops drawing, measured down from its own top edge, and where that top edge
    /// and the pane's own are. Each is nil until something has measured it — iOS 17 has no
    /// scroll geometry to read at all — and the pane is drawn whole while any of them is.
    @State private var contentBottomInTranscript: CGFloat?
    @State private var transcriptTop: CGFloat?
    @State private var paneTop: CGFloat?
    /// Where the memory's folder lives, and the control that moves it: the settings sheet's
    /// Memory section, and what the offer card above the composer opens.
    @State private var showMemory = false
    /// The offer card's answer, once and for good: Choose folder or Not now. It is the chat's
    /// rather than the sheet's, because the card it answers is drawn here.
    @AppStorage("memoryOfferAnswered") private var memoryOfferAnswered = false
    #if DEBUG
    /// The last spoken turn's nonce, for the badge's debug report.
    @State private var spokenNonce: String?
    /// Where Topo stands, for the badge's debug report.
    @State private var mascotReport: MascotRoam.Report?
    #endif

    /// How long the answering loop waits between passes. Five seconds, except in a debug build
    /// launched with `TOPO_DEBUG_LOOP_SECONDS`, which is how a device test tells a revision that
    /// arrived by push from one the loop would have fetched anyway.
    static var loopInterval: Duration {
        #if DEBUG
        if let seconds = DebugRun.loopSeconds() { return .seconds(seconds) }
        #endif
        return .seconds(5)
    }

    /// The chat, told whether the keyboard is on screen by the keyboard's own safe area. The
    /// reader is the whole screen, so what it reads is the bottom inset the keyboard sets, and it
    /// reads it inside the transaction the keyboard's rise and fall is animated in: the pane going
    /// short and tall again is laid out in that same transaction, so it moves on the keyboard's
    /// own curve and reaches its end with it, and the transcript is laid out once for both.
    var body: some View {
        GeometryReader { screen in
            let keyboard = KeyboardInset.isUp(bottom: screen.safeAreaInsets.bottom, resting: restingBottomInset)
            // The keyboard's top edge is the bottom of this reader's frame while it is up.
            chat(keyboard: keyboard, keyboardTop: keyboard ? screen.frame(in: .global).maxY : nil)
        }
        // The same inset with the keyboard's region ignored, which is the screen's own.
        .background {
            GeometryReader { screen in
                Color.clear.onChange(of: screen.safeAreaInsets.bottom, initial: true) { _, bottom in
                    restingBottomInset = bottom
                }
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    private func chat(keyboard: Bool, keyboardTop: CGFloat?) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if harness.busy {
                    // A turn in flight always says where it is; a spinner alone reads as nothing.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(harness.status ?? "Working…")
                        if harness.waiting.count > 1 {
                            Text("· \(harness.waiting.count - 1) waiting").foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .mascotObstacle()
                    .padding(.bottom, 8)
                }
                if let error = harness.error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).mascotObstacle()
                        .padding(.bottom, 8)
                }
                if let info = harness.info {
                    Text(info).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).mascotObstacle()
                        .padding(.bottom, 8)
                }
                if harness.hasWaiting {
                    // The line stopped on a failure; what was said is kept and goes again from here.
                    lineButton(harness.waiting.count == 1 ? "Send \"\(harness.waiting[0])\" again"
                                                          : "Send \(harness.waiting.count) waiting") {
                        await harness.retry()
                    }
                } else if let unfinished = harness.unfinished, !harness.busy {
                    // The guest was cut off answering this turn. It may have run tools, so it is
                    // never asked again by itself: only this, which the person chooses.
                    lineButton("Unfinished: ask \"\(unfinished.text)\" again") {
                        await harness.askAgain()
                    }
                }
            }
            // The composer is a bar under the transcript, and the inset is the whole of its
            // declaration: the transcript scrolls under it while there is more to scroll, and
            // at rest the last turn stops above it. What says whether anything is behind the
            // pane is the presence, below, and not the modifier.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    // Once, and only while the memory is still in this app's own folder and has
                    // more than a handful in it. Not now is for good: no nag, no timer.
                    if memory.offersICloudDrive(answered: memoryOfferAnswered) {
                        MemoryOfferCard(choose: {
                            memoryOfferAnswered = true
                            showMemory = true
                        }, notNow: {
                            memoryOfferAnswered = true
                        })
                        .mascotObstacle()
                    }
                    composer(keyboard: keyboard)
                }
            }
            // The one space the transcript's content bottom and the pane's top edge are both
            // measured in, so the two numbers the presence is worked out from are comparable.
            .coordinateSpace(.named(Self.space))
            // Topo, over all of it: he stands where the turns, the lines under them and the glass
            // leave him room, and is not drawn where they leave none. The glass is never his.
            .mascotRoams(mascot.state, opacity: micState.holding ? look.composer.flank.heldOpacity : 1,
                         covered: showSettings || showDiagnostics || showMemory, keyboardTop: keyboardTop,
                         ready: transcriptRead, report: mascotReported,
                         // The facing each roost decides, off the view update it arrives in.
                         face: { facing in Task { @MainActor in mascot.facing = facing } })
            // The mark says the name, so the title says it twice.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The jewel is the glass here, so from iOS 26 on the bar puts none of its own
                // behind it. That is a shape the bar draws rather than a value the badge does,
                // so it is an availability branch and not a `Look` field.
                if #available(iOS 26, *) {
                    badgeItem.sharedBackgroundVisibility(.hidden)
                } else {
                    badgeItem
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(signOut: signOut) }
            // The diagnostics are the badge's own, held rather than tapped, so they open from
            // here as well as from the sheet: a screen that will not draw is still reachable.
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            // The memory screen is the sheet's Memory section, and also what the offer card
            // above the composer opens, so the chat presents it too.
            .sheet(isPresented: $showMemory) { MemoryView() }
        }
        .task {
            #if DEBUG && os(iOS)
            // Before the keyboard is first asked for: a suite that presses the short well asks
            // for the keyboard a phone has, not the Mac's.
            DebugRun.softwareKeyboard()
            #endif
            // The mirror runs on every pass of the loop below, which is what makes the folder
            // current with no push and no turn. It is installed before the first turn of all,
            // not after it: the first-run answer is a turn like any other, and a screen that
            // installed this after sending would leave that one turn's work for whatever cue
            // came next. What a revision's push wakes is put up with the login rather than with
            // this screen (`MemoryWake`, from `TopoApp`).
            harness.onPass = { [memory] in await memory.sync() }
            defer { harness.onPass = nil }
            await harness.refresh()
            // The row comes back before anything is sent from it: words on their way when the
            // app last went away are the row's again, under the nonce they were first said with,
            // so the way back from a turn that never landed is where it always is.
            row.resume(from: harness)
            // Words on their way when the app last went away go first, under their own nonce.
            // Otherwise the first-run answer is the first turn, once, only when the log is empty;
            // it clears once it is in the log so a stale read on a later launch cannot resend it.
            if harness.hasWaiting {
                await harness.retry()
            } else if harness.turns.isEmpty, !firstRunAnswer.isEmpty, !harness.busy {
                let answer = firstRunAnswer
                await harness.send(answer)
                if harness.turns.contains(where: { $0.role == .person && $0.text == answer }) {
                    answered = true
                    firstRunAnswer = ""
                }
            }
            // From here the screen stays current and, as primary, answers what the other devices
            // write into the log. A limb's turn also wakes the loop by a silent push (`TurnPush`),
            // which runs its next pass now instead of beside it; the handler stands exactly as
            // long as the loop does, so a push after a sign-out or a takeover reaches nothing.
            // The subscription is saved beside the loop: cheap when it is already there, and a
            // failure costs only the acceleration, so it is not the screen's to report.
            PushWake.install { [harness] in await harness.wake() }
            // A turn that ended in a failure is owed no reply, so nothing waits for one.
            harness.onTurnFailed = { nonce in speaker.endAwaiting(nonce, "the turn failed") }
            defer { PushWake.remove() }
            // A spoken question gets a spoken answer, and the decision is the log's rather than
            // the screen's: behind the lock nothing is drawn, and whether a view's observer runs
            // is the framework's to decide. It fires for a reply this phone wrote and for one
            // another primary wrote that the log brought, once for either.
            harness.onReply = { reply in
                // The mark is the decision, made at the release: a reply whose turn is marked is
                // read whatever the setting says now, since the setting governs what the next
                // release decides and not what a turn already released is owed.
                guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
                // Only a reply the speaker took is read: one it refused is still owed, so the
                // turn stays marked spoken and the next pass offers the reply again.
                guard speaker.speak(reply.text, answering: asked) else { return false }
                harness.answeredAloud(asked)
                return true
            }
            // A turn that ended in a failure is owed no reply, so nothing waits for one.
            harness.onTurnFailed = { nonce in speaker.endAwaiting(nonce, "the turn failed") }
            defer {
                // Sign-out, a takeover, the screen going: nothing here is going to read a reply
                // aloud any more, so nothing keeps the process awake for one.
                harness.onReply = nil
                harness.onTurnFailed = nil
                speaker.endAllWaits("the chat stopped answering")
            }
            await withDiscardingTaskGroup { group in
                group.addTask { try? await TurnPush.ensureSubscription() }
                await harness.answering(every: Self.loopInterval)
            }
        }
        .task {
            // The far end of a takeover: another device wrote this one's role as viewer, so it
            // stops answering, forgets its login, and the root shows the viewer screen.
            while !Task.isCancelled {
                if await roleSelector.demotionRecorded() {
                    // What was waiting goes into the log first, while this screen and its task
                    // still stand; the role flips after, and the login goes last.
                    await harness.demote()
                    roleSelector.acceptDemotion()
                    // The login goes, so the reply being read goes with it, as at a sign-out,
                    // and so does the folder: a viewer holds no login and keeps no memory.
                    speaker.stop()
                    memory.forget()
                    signIn.signOut()
                    return
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        // Topo on the glass wears the model the harness asks and the context of its last reply.
        .onChange(of: harnessFacts, initial: true) { _, facts in
            mascot.harness(model: facts.model, tokens: facts.context)
        }
        .onChange(of: voice.text) { _, text in if voice.owner == .chat, !text.isEmpty { row.text = text } }
        // The row holds the turn's words until the turn is in the log, and the log is what ends
        // it: a turn whose reply failed is in the log like any other, so the row clears and the
        // bubble that lands is the one that was being written in. A turn that never reached the
        // log is owed, so the row stays as it is and the outbox sends it again.
        .onChange(of: landed) { _, inTheLog in
            guard inTheLog else { return }
            row.clearIfLanded(in: harness)
        }
        // The keyboard coming up ends a hands-free session: a person who has started typing is
        // not still talking. What was heard stays in the row, to be finished by hand.
        .onChange(of: row.typing) { _, up in if up { voice.cancel(.chat) } }
        .onChange(of: scenePhase) { _, phase in
            // A microphone open when the scene goes is dropped, words and all: nobody is holding
            // it, so nothing said into it was meant. A reply plays on — that is what the hold is
            // for — and the press that starts the next one is what stops it.
            if phase != .active { voice.cancel(.chat) }
        }
        .onDisappear { voice.cancel(.chat) }
    }

    /// A control under the transcript that sends something again: the line stopped on a failure,
    /// or a turn the guest was cut off answering.
    private func lineButton(_ title: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .font(.footnote)
        .mascotObstacle()
        .padding(.bottom, 8)
    }

    /// The mark at the trailing edge, and what the spoken-turn test reads off it.
    private var badgeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            TopoBadge(openSettings: { showSettings = true },
                      openDiagnostics: { showDiagnostics = true })
                #if DEBUG
                // What the spoken-turn UI test decodes: the last spoken turn, its reply, and
                // what the speaker did with it, as JSON (`DebugRun.ChatReport`).
                .accessibilityIdentifier(DebugRun.chatReportIdentifier)
                .accessibilityValue(DebugRun.chatReport(spoken: spokenNonce, turns: harness.turns,
                                                        error: harness.error, speaker: speaker.report,
                                                        voice: speaker.voice.state, mascot: mascotReport,
                                                        facing: mascot.facing, clearance: look.mascot.clearance))
                #endif
        }
    }

    /// The way out, built here because this is where the four things it ends are in scope, and
    /// handed to the settings sheet. The far end of a takeover, below, ends the same things by
    /// its own path, since a demotion writes what is waiting into the log first.
    private var signOut: SignOut {
        SignOut(stopSpeaking: { speaker.stop() }, forgetHarness: { await harness.forget() },
                forgetMemory: { memory.forget() }, forgetLogin: { signIn.signOut() })
    }

    /// Hold to talk and release to send; a tap opens the microphone until the next press. The
    /// session logic is `VoiceInput`'s; this only sends what a press hands back.
    private func micPressed(_ down: Bool) async {
        if down { speaker.stop() }
        let heard = down ? await voice.pressDown(as: .chat) : await voice.pressUp(as: .chat)
        guard let heard else { return }
        await sendSpoken(heard)
    }

    private func sendSpoken(_ heard: String) async {
        row.text = ""
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        #if DEBUG
        if DebugRun.keepsSpoken() {
            DebugRun.say("heard, not sent: \(heard)")
            return
        }
        #endif
        // The reply to this will be read aloud, so the process is held open from here: the turn
        // is written, asked and answered behind the lock. Nothing is held for a reply that could
        // not be heard anyway — the setting off, or a voice that is not resident.
        // The wait says whether the reply will be read aloud, which is what marks the turn as
        // spoken; whether the process is being kept running for it is its own answer, and this
        // screen states no condition of its own either way.
        // What was heard stands in the row as the turn on its way, rather than vanishing between
        // the release and the log: the bubble being written in is the bubble that lands.
        guard let nonce = row.send(heard: heard, via: harness) else { return }
        if speaker.awaitReply(nonce, readAloud: readAloud).spoken { harness.markSpoken(nonce) }
        #if DEBUG
        spokenNonce = nonce
        #endif
        await harness.retry()
    }

    /// The name of the space both edges are measured in.
    private static let space = "chat"

    /// The transcript, and — from iOS 18, which is where there is a scroll geometry to read —
    /// where its content ends and where its own top edge is. On iOS 17, the deployment target,
    /// there is neither: nothing is measured and the pane is drawn whole, which is the pane as
    /// it was before it had a presence. This is the one availability branch on this screen.
    @ViewBuilder private var transcript: some View {
        let view = TranscriptView(turns: shownTurns, notice: harness.notice,
                                  // Holding one of Topo's turns says it again, which is how a
                                  // typed turn's reply — never read aloud as it lands — is heard.
                                  replay: Replay(speaking: speaker.speaking,
                                                 canSpeak: speaker.voice.ready,
                                                 say: { speaker.speak($0) },
                                                 stopSpeaking: { speaker.stop() }),
                                  actions: turnActions,
                                  draft: draftRow)
        if #available(iOS 18, *) {
            view
                // Where the transcript stops drawing, measured down from the transcript's own
                // top edge. `contentOffset` is the content's y at the top of the scroll view's
                // frame, which reaches under the navigation bar; taking the top inset off puts
                // the number back at the edge of the frame this view was laid out in, which is
                // what `transcriptTop` is measured for. The stack's own trailing padding comes
                // off with it: those points are content and draw nothing, so a pane over them
                // is a pane over nothing.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y
                        - geometry.contentInsets.top - look.transcript.spacing
                } action: { _, bottom in contentBottomInTranscript = bottom }
                .topEdge(in: Self.space) { transcriptTop = $0 }
        } else {
            view
        }
    }

    /// How much of a pane the pane is. One while any of the three edges is unmeasured: iOS 17
    /// measures none of them, and a launch has not measured them yet. One while the row's field
    /// holds focus, which is the keyboard asked for, whatever the geometry.
    private var panePresence: Double {
        guard let contentBottomInTranscript, let transcriptTop, let paneTop else { return 1 }
        return PanePresence.of(contentBottom: transcriptTop + contentBottomInTranscript,
                               paneTop: paneTop, rise: look.composer.presenceRise,
                               open: micState.open, keyboard: focused)
    }

    /// The four facts the glass draws the microphone from, read off `VoiceInput`.
    private var micState: Composer.MicState {
        Composer.MicState(canListen: voice.canListen, listening: voice.listening,
                          owner: voice.owner, handsFree: voice.handsFree)
    }

    /// The glass under the transcript. What the microphone is doing is four facts read off
    /// `VoiceInput` here and drawn there; the press is handed straight back to `micPressed`,
    /// which is the whole of this screen's part in a session. Its own top edge is read off its
    /// geometry rather than worked out, so the offer card above it and the keyboard's rise move
    /// the edge the presence is read against.
    @ViewBuilder private func composer(keyboard: Bool) -> some View {
        let view = Composer(typing: Bindable(row).typing, mic: micState, presence: panePresence,
                            keyboard: keyboard,
                            micPressed: { down in Task { await micPressed(down) } },
                            micReport: micReport)
        if #available(iOS 18, *) {
            view.topEdge(in: Self.space) { paneTop = $0 }
        } else {
            view
        }
    }

    /// What the chat's harness says of the model and the context, for Topo: the model the debug
    /// build's pin makes of the setting, since that is the model that answers.
    private var harnessFacts: HarnessFacts {
        HarnessFacts(model: ClaudeModel.effective(ClaudeModel(rawValue: modelSetting) ?? .default).rawValue,
                     context: harness.context)
    }

    private struct HarnessFacts: Equatable {
        var model: String
        var context: Int?
    }

    /// Whether what the transcript draws is the log's: once it has been read, or at once for a
    /// debug build's fixture.
    private var transcriptRead: Bool {
        #if DEBUG
        if DebugRun.transcript() != nil { return true }
        #endif
        return harness.hasRead
    }

    /// The turns the transcript draws: the log's, or in a debug build launched with
    /// `TOPO_DEBUG_TRANSCRIPT` the fixture it names.
    private var shownTurns: [Turn] {
        #if DEBUG
        if let fixture = DebugRun.transcript() { return fixture }
        #endif
        return harness.turns
    }

    /// Where Topo stands, into the badge's debug report, off the view update it arrives in. Nil in
    /// a release build, which reports nothing.
    private var mascotReported: ((MascotRoam.Report) -> Void)? {
        #if DEBUG
        return { report in Task { @MainActor in mascotReport = report } }
        #else
        return nil
        #endif
    }

    /// What the UI suites decode off the microphone after a press. A debug build only, so
    /// VoiceOver on a release build hears the label alone.
    private var micReport: String? {
        #if DEBUG
        return voice.debugReport
        #else
        return nil
        #endif
    }

    private func send() {
        voice.cancel(.chat)
        guard row.send(via: harness) != nil else { return }
        Task { await harness.retry() }
    }

    /// What holding a turn in the transcript offers. Holding one of the person's own puts its
    /// words back into the row: the log is append-only, so this edits what is said next and never
    /// the turn that was said. It is offered only while the row is free to take them — the row
    /// draws the words being sent until they land or are taken back — and `NextTurn.edit` refuses
    /// them over a turn on its way whether or not the item is there.
    private var turnActions: TurnActions {
        guard !row.sending(in: harness) else { return TurnActions() }
        let take: @MainActor (Turn) -> Void = { row.edit($0, in: harness) }
        return TurnActions(edit: take)
    }

    /// The person's next turn, at the end of the transcript, as the row draws it. What is written
    /// and whether the keyboard is asked for are the row's own state, bound both ways; the rest is
    /// read off it and off the log.
    private var draftRow: Draft {
        let bindable = Bindable(row)
        return Draft(text: bindable.text, typing: bindable.typing,
                     sending: row.sending(in: harness), send: send, edit: editSending,
                     focused: { focused = $0 }, holdsKeyboard: focused)
    }

    /// The turn the row is holding is in the log — answered, or answered by nothing, which are
    /// the same thing to the row: the words are said either way and a second send would be a
    /// second turn.
    private var landed: Bool {
        guard let sent = row.sent else { return false }
        return harness.said(sent)
    }

    /// The way back from a turn that never reached the log: the words come off the line and stay
    /// in the row to be changed, so what is said again is one turn under one nonce. Nil while
    /// there is nothing to take back, which is what leaves the row with no way out of a turn that
    /// is genuinely on its way.
    private var editSending: (@MainActor () -> Void)? {
        guard row.canWithdraw(in: harness) else { return nil }
        return {
            Task {
                guard let taken = await row.withdraw(via: harness) else { return }
                // Nothing is coming for a turn that was never said, so nothing waits for it.
                speaker.endAwaiting(taken, "the turn was taken back")
            }
        }
    }
}

@available(iOS 18, *)
private extension View {
    /// One view's top edge in a named space, reported as it moves. `onGeometryChange` rather
    /// than a `GeometryReader` behind the view: it is the view's own geometry, read after every
    /// layout, where a reader in a background reports the size it is given and can be read
    /// before there is one.
    func topEdge(in space: String, _ report: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { report($0) }
    }
}

/// Which replies are read aloud as they land: one continuing from a turn this screen sent from
/// the microphone. A reply names that turn among its parents, not necessarily first: `answerPending`
/// joins every head of a forked log, sorted by ref, so another device's turn can come before it.
enum ReadAloud {
    /// The nonce of the spoken turn `reply` answers, or nil when it answers none.
    static func spokenTurn(answeredBy reply: Turn, in turns: [Turn], spoken: Set<String>) -> String? {
        guard reply.role == .assistant, !spoken.isEmpty else { return nil }
        return reply.parents.lazy
            .compactMap { ref in turns.first { $0.ref == ref } }
            .first { $0.role == .person && spoken.contains($0.nonce) }?
            .nonce
    }
}
#endif
