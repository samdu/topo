#if os(iOS)
import SwiftUI
import TopoAuth
import TopoCore
import TopoTurn

/// Single-device chat: the transcript from the log, the glass under it holding the microphone
/// and the field the next turn is written in, and the model and the mute in the bar above.
struct ChatView: View {
    @Environment(Harness.self) private var harness
    @Environment(SignIn.self) private var signIn
    @Environment(RoleSelector.self) private var roleSelector
    @Environment(Memory.self) private var memory
    @Environment(Connections.self) private var connections
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""
    @AppStorage("firstRunAnswered") private var answered = false
    @Environment(VoiceInput.self) private var voice
    @Environment(Speaker.self) private var speaker
    @Environment(\.look) private var look
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Mascot.self) private var mascot
    @AppStorage(Mute.key) private var readAloud = true
    /// The model chosen on the bar's slider, which is the head Topo wears between the guest's turns
    /// (during one, the model the guest reports).
    @AppStorage(Harness.modelKey) private var modelSetting = ClaudeModel.default.rawValue
    /// The person's next turn: what is written, whether the keyboard is asked for, and the turn
    /// those words are on their way under. It is a `NextTurn` rather than this screen's own
    /// state because what it holds outlives the screen — an app killed with words on the line
    /// comes back to the row they were sent from.
    @State private var row = NextTurn()
    /// The pane's field holds focus: the pane is present while it does. Not `row.typing`, which
    /// outlives the field while a turn is on its way. It is the presence's and not the pane's
    /// form, because it changes in a transaction of its own ahead of the keyboard, so the
    /// surface fades in on the presence's time where it stands and then rides up with the pane.
    @State private var focused = false
    /// The field has held focus `ComposerForm.patience` with no keyboard on screen, so none is
    /// coming and the pane is a row for the focus alone.
    @State private var alone = false
    /// Where what the microphone hears goes, taken when its session began.
    @State private var dictation = Dictation.spoken
    /// Which way the press on the microphone went, so its release follows it.
    @State private var micPress = MicPress()
    /// The bottom of the screen's safe area with no keyboard in it, which is what the keyboard's
    /// is measured against (`KeyboardInset`). Nil until it has been measured.
    @State private var restingBottomInset: CGFloat?
    /// The model slider is open across the middle of the bar, and where its chosen stop is in the
    /// global space, which is what Topo hangs under while it is.
    @State private var modelsOpen = false
    @State private var modelStop: CGRect?
    @State private var showSettings = false
    @State private var showDiagnostics = false
    /// The two edges the pane's presence is read from, in the chat's own space: where the
    /// transcript stops drawing, measured down from its own top edge, and where that top edge
    /// and the pane's own are. Each is nil until something has measured it — iOS 17 has no
    /// scroll geometry to read at all — and the pane is drawn whole while any of them is.
    @State private var contentBottomInTranscript: CGFloat?
    #if DEBUG
    /// What a tap on a reply's link asked to be opened, over a fixture transcript.
    @State private var debugOpened: [URL] = []
    #endif
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
                // A keyboard that is coming is on screen within a few frames of the focus; one
                // that has not come by then is not coming (`ComposerForm`). The pane takes the
                // focus alone on a curve of its own, there being no keyboard's to move on.
                .task(id: [focused, keyboard]) {
                    let take = { (now: Bool) in
                        guard alone != now else { return }
                        withAnimation(.easeInOut(duration: look.composer.duration)) { alone = now }
                    }
                    // Under a keyboard the form is the keyboard's, and nothing is drawn differently
                    // for the focus no longer being alone, so nothing is animated.
                    if let settled = ComposerForm.alone(focused: focused, keyboard: keyboard) {
                        if keyboard { alone = settled } else { take(settled) }
                        return
                    }
                    do { try await Task.sleep(for: ComposerForm.patience) } catch { return }
                    // A wait that ran out as the keyboard came is not the keyboard not coming.
                    guard !Task.isCancelled else { return }
                    take(true)
                }
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
        let draft = draft(row: ComposerForm.isRow(keyboard: keyboard, focused: focused, alone: alone))
        return NavigationStack {
            ChatColumn(keyboard: keyboard) {
                transcript(draft)
            } line: {
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
            } card: {
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
            } pane: { room in
                composer(draft, room: room)
            }
            // The one space the transcript's content bottom and the pane's top edge are both
            // measured in, so the two numbers the presence is worked out from are comparable.
            .coordinateSpace(.named(Self.space))
            // Topo, over all of it, where the look places him: roaming where the turns, the lines
            // under them and the glass leave him room, on the glass, or at a pin.
            .mascotRoams(mascot.drawn, opacity: micState.holding ? look.composer.flank.heldOpacity : 1,
                         covered: showSettings || showDiagnostics || showMemory, keyboardTop: keyboardTop,
                         stop: modelsOpen ? modelStop : nil, ready: transcriptRead, report: mascotReported,
                         // The facing each roost decides, off the view update it arrives in.
                         face: { facing in Task { @MainActor in mascot.facing = facing } },
                         // A drag let go of him: this device keeps the pin, over the vault's look.
                         pin: { pin in Tuning.shared.pin(at: pin) })
            // The mark says the name, so the title says it twice.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                bar
                middle
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
            Perf.mark("chat.appear")
            // The guest and its resident Claude Code are started beside the first read of the log
            // rather than after it: Claude Code takes longer to come up than the log takes to
            // read, and a question asked into a cold app waits for both. This waits for nothing.
            if let guest = harness.guest { Task { await guest.warm() } }
            await harness.refresh()
            Perf.mark("chat.log.read")
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
            // And before it lands: the reply to a spoken turn is read as the guest writes it.
            // Muted, neither is read: the mute is asked as each comes, off the defaults and not
            // this view's copy, which a task started earlier does not see change.
            SpokenReply.follow(harness, speaker: speaker) { Mute.readsAloud() }
            defer {
                // Sign-out, a takeover, the screen going: nothing here is going to read a reply
                // aloud any more, so nothing keeps the process awake for one.
                harness.onReply = nil
                harness.onWriting = nil
                harness.onTurnFailed = nil
                speaker.settled = nil
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
                    await takeover.act()
                    return
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        // Topo on the glass wears the model the harness asks and the context of its last reply.
        .onChange(of: harnessFacts, initial: true) { _, facts in
            mascot.harness(model: facts.model, tokens: facts.context)
        }
        // And under the open model slider, the model chosen there, which no turn's events change.
        .onChange(of: sliderChoice, initial: true) { _, chosen in mascot.chosen = chosen }
        // A failure is said in the middle of the bar, where the open slider is: it shuts.
        .onChange(of: shownNotices.notice) { _, notice in
            if case .trouble = notice { modelsOpen = false }
        }
        // What the microphone has heard so far is written where its session is going: over the
        // draft for a turn that will be sent on the release, after what was written for one that
        // will not.
        .onChange(of: voice.text) { _, text in
            guard voice.owner == .chat, !text.isEmpty, dictation.standing(in: row.text) else { return }
            let written = dictation.written(hearing: text)
            if row.caption(written) { dictation.wrote = written }
        }
        // Typing into a draft the microphone is dictating into ends the dictation, as raising
        // the keyboard ends a spoken turn: what was heard so far stays, and what is typed is not
        // written over by the next caption.
        .onChange(of: row.text) { _, text in
            guard voice.owner == .chat, voice.listening, !dictation.standing(in: text) else { return }
            voice.cancel(.chat)
        }
        // The row holds the turn's words until the turn is in the log, and the log is what ends
        // it: a turn whose reply failed is in the log like any other, so the row clears and the
        // bubble that lands is the one that was being written in. A turn that never reached the
        // log is owed, so the row stays as it is and the outbox sends it again.
        .onChange(of: landed) { _, inTheLog in
            guard inTheLog else { return }
            row.clearIfLanded(in: harness)
        }
        // The keyboard coming up ends a hands-free session: a person who has started typing is
        // not still talking. What was heard stays in the draft, to be finished by hand.
        .onChange(of: row.typing) { _, up in
            guard up else { return }
            voice.cancel(.chat)
        }
        // What the look calls the models is what the notice calls them.
        .onChange(of: look.mind, initial: true) { _, mind in harness.mind = mind }
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

    /// The model and the mute, at the bar's leading edge, each an item of its own (`ChatBar`), so
    /// neither shares the other's glass. The model's control opens the slider and shuts it.
    /// Muting ends what is being read and what was waited for, as Stop does; a reply that lands
    /// muted is read by nobody (`SpokenReply`).
    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ChatBar.ModelButton(chosen: harness.name(of: chosenModel), open: modelsOpen,
                                setOpen: { open in
                                    if !open { modelStop = nil }
                                    modelsOpen = open
                                })
        }
        // From iOS 26 on the bar draws neighbouring items on one piece of glass; the room
        // between them is the bar's to give, so this is an availability branch and not a `Look`
        // field.
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarLeading)
        }
        ToolbarItem(placement: .topBarLeading) {
            ChatBar.Mute(readsAloud: readAloud,
                         setReadsAloud: { on in
                             readAloud = on
                             SpokenReply.muteChanged(readsAloud: on, speaker: speaker)
                         })
        }
    }

    /// The model the setting names, which is what the slider's knob is on and not what a debug
    /// build's pin makes of it.
    private var chosenModel: ClaudeModel { ClaudeModel(setting: modelSetting) ?? .default }

    /// The model chosen on the model slider while it is open, which is the head Topo wears under
    /// it in every build and through a turn (`Mascot.chosen`); nil while it is shut.
    private var sliderChoice: String? { modelsOpen ? chosenModel.rawValue : nil }

    /// The middle of the bar, between the controls and the badge: the model slider while it is
    /// open, and otherwise what the chat says it is doing (`ChatNotices`). The bar holds one of
    /// them, and the slider is there only while somebody is choosing. A stop sets the harness's
    /// model, which is the setting. An item is there only while there is something to draw: an
    /// item the bar first laid out empty is one it never draws, whatever it later holds.
    @ToolbarContentBuilder private var middle: some ToolbarContent {
        let said = shownNotices
        if modelsOpen {
            ToolbarItem(placement: .principal) {
                ChatBar.Slider(models: ClaudeModel.allCases.map { .init(id: $0.rawValue, name: harness.name(of: $0)) },
                               chosen: chosenModel.rawValue,
                               choose: { alias in
                                   if let model = ClaudeModel(setting: alias), model != harness.model { harness.model = model }
                               },
                               stop: { modelStop = $0 })
            }
        } else if said.any {
            ToolbarItem(placement: .principal) { ChatNotices(notices: said) }
        }
    }

    /// The harness's notices, or in a debug build the fixture `TOPO_DEBUG_NOTICES` names.
    private var shownNotices: ChatNotices.Said {
        #if DEBUG
        if let fixture = DebugRun.notices { return fixture }
        #endif
        return ChatNotices.Said(harness)
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
                                                        facing: mascot.facing, clearance: look.mascot.clearance,
                                                        placed: look.mascot,
                                                        overridePlacement: Tuning.shared.placement,
                                                        overridePin: Tuning.shared.pin,
                                                        presence: panePresence,
                                                        contentBottom: contentBottomInTranscript,
                                                        opened: debugOpened,
                                                        guestHome: GuestImages.Mounts.shared.home,
                                                        model: harness.model))
                #endif
        }
    }

    /// The far end of a takeover, built here for the same reason as the way out below.
    private var takeover: Takeover {
        Takeover(demoteHarness: { await harness.demote() }, acceptDemotion: { roleSelector.acceptDemotion() },
                 stopSpeaking: { speaker.stop() }, forgetMemory: { memory.forget() },
                 forgetSurfaces: { SurfaceReloader.shared.forget(SurfaceStore.shared()) },
                 forgetConnections: { connections.forget() },
                 forgetLogin: { signIn.signOut(unfinished: connections.unforgotten) })
    }

    /// The way out, built here because this is where the five things it ends are in scope, and
    /// handed to the settings sheet. The far end of a takeover, below, ends the same things by
    /// its own path, since a demotion writes what is waiting into the log first.
    private var signOut: SignOut {
        SignOut(stopSpeaking: { speaker.stop() }, forgetHarness: { await harness.forget() },
                forgetMemory: { memory.forget() }, forgetSurfaces: { SurfaceReloader.shared.forget(SurfaceStore.shared()) },
                forgetConnections: { connections.forget() },
                forgetLogin: { signIn.signOut(unfinished: connections.unforgotten) })
    }

    /// What a session of the microphone heard, sent where the session was going when it began
    /// (`Dictation`). One begun over the row is written after what was there and sends nothing:
    /// the send in the glass sends it, as the typed turn it is.
    private func heard(_ heard: String, _ going: Dictation) async {
        guard going.sends else {
            // What the session last wrote is the screen's to know, where its captions went; a
            // draft typed into since is left as it is.
            var session = going
            if dictation.over == going.over { session.wrote = dictation.wrote }
            guard session.standing(in: row.text) else { return }
            let written = session.written(hearing: heard)
            if row.caption(written), dictation.over == going.over { dictation.wrote = written }
            return
        }
        await sendSpoken(heard)
    }

    private func sendSpoken(_ heard: String) async {
        // The caption goes; a turn the row is holding on its way stays, whatever was heard.
        row.endCaption()
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
    @ViewBuilder private func transcript(_ draft: Draft) -> some View {
        let view = TranscriptView(turns: shownTurns, notice: harness.notice,
                                  // Holding one of Topo's turns says it again, which is how a
                                  // typed turn's reply — never read aloud as it lands — is heard.
                                  replay: Replay(speaking: speaker.speaking,
                                                 canSpeak: speaker.voice.ready,
                                                 say: { speaker.speak($0.text, reply: $0.ref) },
                                                 stopSpeaking: { speaker.stop() }),
                                  actions: turnActions,
                                  draft: draft, queued: row.queued(in: harness), answer: row.answer(in: harness),
                                  cue: speaker.cue)
            // An image in a reply is read as the guest reads it, once there is a guest.
            .environment(\.replyImages, GuestImages.reader(epoch: GuestImages.Mounts.shared.epoch))
            #if DEBUG
            .recordingLinks { debugOpened.append($0) }
            #endif
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
    /// measures none of them, and a launch has not measured them yet. One while the pane's field
    /// holds focus, which is the keyboard asked for, whatever the geometry, and while Topo sits
    /// on the glass.
    private var panePresence: Double {
        guard let contentBottomInTranscript, let transcriptTop, let paneTop else { return 1 }
        return PanePresence.of(contentBottom: transcriptTop + contentBottomInTranscript,
                               paneTop: paneTop, rise: look.composer.presenceRise,
                               open: micState.open, keyboard: focused,
                               holdsTopo: look.mascot.placement == .glass)
    }

    /// What the glass draws the microphone from: `VoiceInput`'s four facts and the speaker's one.
    private var micState: Composer.MicState {
        Composer.MicState(voice, speaking: speaker.speaking)
    }

    /// The glass under the transcript. What the microphone is doing is four facts read off
    /// `VoiceInput` here, with whether Topo is speaking, and drawn there; the press is handed
    /// straight back to `MicPress.gesture` with the state the composer drew it in, which is the
    /// whole of this screen's part in a session. Its own top edge is read off its
    /// geometry rather than worked out, so the offer card above it and the keyboard's rise move
    /// the edge the presence is read against.
    @ViewBuilder private func composer(_ draft: Draft, room: CGFloat?) -> some View {
        let view = Composer(draft: draft, mic: micState, presence: panePresence,
                            // Hold to talk and release to send; a tap opens the microphone until
                            // the next press. The session logic is `VoiceInput`'s and the routing
                            // `MicPress`'s; this only says where what a press hands back goes,
                            // which is settled as the session begins and kept to its end: each
                            // press carries it by value, so a later session's is never this one's.
                            micPressed: { down, drawn in
                                // A thumb on the microphone shuts the slider: Topo goes home, and
                                // the bar's middle is the notices' again for the turn.
                                if down {
                                    modelsOpen = false
                                    modelStop = nil
                                }
                                var going = dictation
                                if Dictation.begins(down: down, drawn: drawn) {
                                    going = .beginning(row: draft.row, inFlight: draft.state == .inFlight, written: row.text)
                                    dictation = going
                                }
                                micPress.gesture(down, drawn: drawn, speaker: speaker, voice: voice,
                                                 send: { await heard($0, going) })
                            },
                            micReport: micReport,
                            focused: { focused = $0 },
                            room: room)
        if #available(iOS 18, *) {
            view.topEdge(in: Self.space) { paneTop = $0 }
        } else {
            view
        }
    }

    /// What the chat's harness says of the model and the context, for Topo: the model the debug
    /// build's pin makes of the setting, since that is the model that answers.
    private var harnessFacts: HarnessFacts {
        let setting = ClaudeModel(setting: modelSetting) ?? .default
        return HarnessFacts(model: ClaudeModel.effective(setting).rawValue, context: harness.context)
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
        let behind = row.behind(in: harness)
        // What is being written for words not in the log yet is drawn under those words.
        guard let writing = harness.writing, !writing.isEmpty, !harness.writingAhead else { return harness.turns + behind }
        return harness.turns + behind + [Turn(ref: Self.writingRef, parents: [], role: .assistant, text: writing, at: Date(),
                                              nonce: "writing")]
    }

    /// The row the reply is drawn in while the guest writes it (`Harness.writing`): no turn of
    /// the log's, so no device's sequence can name it.
    private static let writingRef = TurnRef(device: DeviceID("writing"), sequence: 0)

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

    /// The person's next turn, as the glass's field and the row at the end of the transcript
    /// draw it. What is written and whether the keyboard is asked for are `NextTurn`'s own
    /// state, bound both ways; the rest is read off it and off the log, and `row` is the form
    /// the pane is in.
    private func draft(row form: Bool) -> Draft {
        let bindable = Bindable(row)
        return Draft(text: bindable.text, typing: bindable.typing,
                     sending: row.sending(in: harness), row: form, send: send, edit: editSending)
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

/// What the chat says it is doing, in the navigation bar beside the badge rather than over the
/// composer: the turn in flight and where it is, the last failure, and something that went right
/// but not the usual way. They are there to be read when something is slow or wrong, and the
/// glass under the transcript is the controls'. The bar is above the transcript's frame, which is
/// where Topo's room starts, so none of them is his obstacle.
struct ChatNotices: View {
    /// What there is to say, read off the harness.
    struct Said: Equatable {
        var busy = false
        var status: String?
        /// How many turns are on the line, the one in flight included.
        var waiting = 0
        var error: String?
        var info: String?

        /// The one notice the bar shows. The bar holds one, so they take turns: a failure first,
        /// since it is what needs doing something about; then the turn in flight; then a turn
        /// that went right another way, which a later turn's progress replaces.
        var notice: Notice? {
            if let error { return .trouble(error) }
            if busy { return .progress(status ?? "Working…", queued: waiting > 1 ? "· \(waiting - 1) waiting" : nil) }
            if let info { return .info(info) }
            return nil
        }

        /// Whether there is anything to say.
        var any: Bool { notice != nil }
    }

    enum Notice: Equatable {
        /// The last failure, in the look's trouble colour.
        case trouble(String)
        /// Where the turn in flight is — a spinner alone reads as nothing — and the turns behind it.
        case progress(String, queued: String?)
        /// Something that went right but not the usual way.
        case info(String)
    }

    let notices: Said
    /// The most lines the notice takes; nil only where a test lays it out unbounded, to hold that
    /// the bound cut nothing.
    var lineLimit: Int? = ChatNotices.lines
    @Environment(\.look) private var look

    /// What the UI suite finds the notices by.
    static let identifier = "topo-notices"

    /// The most lines the notice takes: the bar holds two beside the badge, and every notice the
    /// harness writes fits two at the largest `noticeFont` on the narrowest phone, drawn no
    /// smaller than `look.transcript.noticeLeastScale` of it.
    static let lines = 2

    /// The largest text setting the notices follow. The bar is a fixed height, so past this the
    /// words would reach down over the transcript; the system's own bar titles stop growing too.
    static let largestType = DynamicTypeSize.xLarge

    var body: some View {
        Group {
            switch notices.notice {
            case .trouble(let error):
                Text(error).foregroundStyle(look.transcript.trouble)
            case .progress(let where_, let queued):
                HStack {
                    ProgressView()
                    // One text, so the turns behind wrap with the status and take no width of
                    // their own beside it: between the bar's controls and the badge there is not
                    // the room for the longest status in two lines and a count beside it.
                    if let queued {
                        Text("\(Text(where_)) \(Text(queued).foregroundStyle(look.transcript.caption))")
                    } else {
                        Text(where_)
                    }
                }
            case .info(let info):
                Text(info).foregroundStyle(look.transcript.caption)
            case nil:
                EmptyView()
            }
        }
        .font(look.transcript.noticeFont)
        .lineLimit(lineLimit)
        // Between the bar's controls and the badge there is not the room for the longest notice
        // at the largest font in two lines, so one that does not fit is drawn smaller before
        // any of it is cut.
        .minimumScaleFactor(look.transcript.noticeLeastScale)
        .truncationMode(.tail)
        .dynamicTypeSize(...Self.largestType)
        .multilineTextAlignment(.center)
        // The bar offers its item one line; a notice is read whole, wrapping below it.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }
}

extension ChatNotices.Said {
    @MainActor init(_ harness: Harness) {
        self.init(busy: harness.busy, status: harness.status, waiting: harness.waiting.count,
                  error: harness.error, info: harness.info)
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

/// Reads a reply that waited for the microphone once the microphone closes, however it closed —
/// a release, the keyboard, the scene going, a reset — by watching `VoiceInput.listening`. Not a
/// view, so it runs behind the lock and whether or not the chat is drawn; the app starts it once.
/// A press closes the microphone too and says so itself (`MicPress`), so the reply does not wait
/// on the watch's hop.
@MainActor
enum MicrophoneWatch {
    static func start(_ voice: VoiceInput, _ speaker: Speaker) {
        withObservationTracking {
            _ = voice.listening
        } onChange: { [weak voice, weak speaker] in
            // Called as the value is about to change, so the answer is read on the next turn.
            Task { @MainActor in
                guard let voice, let speaker else { return }
                if !voice.listening { speaker.microphoneClosed() }
                start(voice, speaker)
            }
        }
    }
}

/// Whether replies to spoken turns are read aloud: the glass's mute, kept in the defaults.
enum Mute {
    static let key = "readAloud"

    /// Read aloud unless muted: a phone that has never been asked reads them.
    static func readsAloud(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

private extension View {
    #if DEBUG
    /// Over a debug build's fixture transcript (`TOPO_DEBUG_TRANSCRIPT`), a tap on a reply's
    /// link is handed to `record` and opens nothing, so a UI suite reads which taps were a
    /// link's. Anywhere else this is the view, and a link opens as the system opens one.
    @ViewBuilder func recordingLinks(_ record: @escaping @MainActor (URL) -> Void) -> some View {
        if DebugRun.transcript() != nil {
            environment(\.openURL, OpenURLAction { url in
                record(url)
                return .handled
            })
        } else {
            self
        }
    }
    #endif
}

/// A spoken turn's reply read aloud: the chat's `Harness.onReply`, answering whether the harness
/// is done with the reply.
@MainActor
enum SpokenReply {
    /// The chat's handlers for a spoken turn, as the screen installs them while it answers.
    static func follow(_ harness: Harness, speaker: Speaker, readsAloud: @escaping @MainActor () -> Bool) {
        wire(harness: harness, speaker: speaker, readsAloud: readsAloud)
        // A turn that ended in a failure, or whose reply the guest finished with iCloud behind,
        // is owed no reply from the log, so nothing waits for one.
        harness.onTurnFailed = { nonce in speaker.endAwaiting(nonce, "the turn failed") }
    }

    /// The harness's reply and the guest's writing of it handed to the speaker, and the speaker's
    /// settling handed back, as the chat has them. `readsAloud` is asked each time: muted, a
    /// reply that lands is read by nobody (`read`), and what the guest writes is not read as it
    /// comes — and that is all a muted delta does, so a reply stopped by the mute stays stopped
    /// (`Speaker` keeps the turn it stopped) and is not begun again from the top when the mute
    /// is lifted.
    static func wire(harness: Harness, speaker: Speaker, readsAloud: @escaping @MainActor () -> Bool) {
        harness.onReply = { reply in
            read(reply, harness: harness, speaker: speaker, muted: !readsAloud())
        }
        harness.onWriting = { text, nonce in
            guard let text else { return speaker.writingEnded(nonce) }
            if readsAloud() { speaker.speak(writing: text, answering: nonce) }
        }
        speaker.settled = { nonce in harness.answeredAloud(nonce) }
    }

    /// The mute pressed: muting ends what is being read and what was waited for, as Stop does.
    static func muteChanged(readsAloud: Bool, speaker: Speaker) {
        if !readsAloud { speaker.stop() }
    }

    static func read(_ reply: Turn, harness: Harness, speaker: Speaker, muted: Bool = false) -> Bool {
        // The mark is the decision, made at the release: a reply whose turn is marked is read,
        // unless the person has muted replies since, which is them saying they will not hear it.
        guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
        if muted {
            speaker.endAwaiting(asked, "replies are muted")
            harness.answeredAloud(asked)
            return true
        }
        // Only a reply the speaker took is read: one it refused is still owed, so the turn stays
        // marked spoken and the next pass offers the reply again.
        guard speaker.speak(reply.text, answering: asked, reply: reply.ref) else { return false }
        // A reply waiting for the microphone keeps its turn marked until it is read
        // (`Speaker.settled`), so one the session refuses when the microphone closes is still owed.
        if !speaker.waitingForMicrophone { harness.answeredAloud(asked) }
        return true
    }
}

extension Composer.MicState {
    /// What the chat's glass draws: the four facts read off `VoiceInput`, and whether the
    /// speaker is reading a reply.
    @MainActor init(_ voice: VoiceInput, speaking: Bool) {
        self.init(canListen: voice.canListen, listening: voice.listening, owner: voice.owner,
                  handsFree: voice.handsFree, speaking: speaking)
    }
}

/// The chat's press on the microphone, routed by the state the composer drew it in. While Topo
/// is speaking the button is Stop (`Composer.MicState.Appearance.stop`): the press ends the reply
/// and opens nothing, and its release is that press's own, so it reaches no session either, even
/// though the button is the microphone again by then. A press on the closed microphone stops a
/// reply still being read, so the microphone does not hear the speaker, and goes to `VoiceInput`;
/// one on the open microphone goes to `VoiceInput` alone, and closing it lets a reply that waited
/// for it be read (`Speaker.microphoneClosed`).
///
/// Every decision is made in the gesture's callback, in the order the callbacks come, and only
/// the call into `VoiceInput` is left to a task: a stop is over before the callback returns and
/// its release spawns nothing, so no scheduling of the tasks can put a release in front of its
/// press or turn one kind of press into the other.
@MainActor
final class MicPress {
    /// The last press down was a stop, so the release that follows it is one too. Set afresh on
    /// every press, so a release the gesture never delivered strands nothing.
    private var stopping = false

    /// The gesture's own call, as the finger lands or lifts, with the state the composer drew
    /// the button in: the press is what the person saw, not what the speaker says by the time
    /// the callback runs. Answers the task carrying the press to `VoiceInput`, and nil for a stop
    /// and its release, which reach nothing. What a release heard is handed to `send`.
    @discardableResult
    func gesture(_ down: Bool, drawn: Composer.MicState, speaker: Speaker, voice: VoiceInput,
                 send: @escaping @MainActor (String) async -> Void) -> Task<Void, Never>? {
        guard down else {
            if stopping {
                stopping = false
                return nil
            }
            return Task {
                let heard = await voice.pressUp(as: .chat)
                speaker.microphoneClosed()
                guard let heard else { return }
                await send(heard)
            }
        }
        stopping = drawn.appearance == .stop
        // A press on a closed microphone stops what is being read, so the mic does not hear it.
        // One on the open microphone leaves the speaker alone: nothing is read while it is open,
        // and a reply waiting for it to close is read once this press closes it.
        if stopping {
            speaker.stop()
        } else if !drawn.open {
            // From here to `pressDown`'s answer the microphone is opening, and nothing is read.
            speaker.microphoneOpening()
        }
        if stopping { return nil }
        return Task {
            let heard = await voice.pressDown(as: .chat)
            speaker.microphoneOpened()
            guard let heard else { return }
            await send(heard)
        }
    }
}

/// What of the chat's column is the room the pane grows in.
enum ChatColumnRoom {
    /// What of a column `tall` is the pane's to grow in, with a line under the transcript and
    /// a card over the pane each taking its own height of it. A height that is not a number
    /// takes nothing.
    static func left(of tall: CGFloat, line: CGFloat, card: CGFloat) -> CGFloat {
        tall - (line.isFinite ? max(line, 0) : 0) - (card.isFinite ? max(card, 0) : 0)
    }
}

/// The chat's column: the transcript with a line under it, and the pane as a bar under both
/// with a card over it. It measures the room the pane has to grow in and hands it to the pane.
struct ChatColumn<Transcript: View, Line: View, Card: View, Pane: View>: View {
    /// Whether the keyboard is on the screen, when the card is not drawn: with the keyboard up
    /// the column has room for the transcript, the line and the pane and for no more, and an
    /// offer nobody answered is still there when the keyboard goes down.
    var keyboard: Bool
    @ViewBuilder var transcript: Transcript
    /// What stands under the transcript, or nothing: a turn to send or ask again.
    @ViewBuilder var line: Line
    /// What stands over the pane while the keyboard is down, or nothing: the memory's offer.
    @ViewBuilder var card: Card
    /// The pane, given the room it has to grow in.
    @ViewBuilder var pane: (CGFloat?) -> Pane

    @State private var lineTall: CGFloat = 0
    @State private var cardTall: CGFloat = 0

    var body: some View {
        // The room the pane has to grow in is this column's: from under the navigation bar to
        // the keyboard, less the line's and the card's heights. It is read from what the column
        // is offered and not from what it is laid out at, since a pane that outgrew the column
        // would push the column's own edges out and be measured as room.
        GeometryReader { column in
            VStack(spacing: 0) {
                transcript
                // A stack of its own, so that a line taken away is measured as no height and
                // not left at its last.
                VStack(spacing: 0) { line }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineTall = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The composer is a bar under the transcript, and the inset is the whole of its
            // declaration: the transcript scrolls under it while there is more to scroll, and
            // at rest the last turn stops above it. What says whether anything is behind the
            // pane is the presence, and not the modifier.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) { if !keyboard { card } }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardTall = $0 }
                    pane(ChatColumnRoom.left(of: column.size.height, line: lineTall, card: cardTall))
                }
            }
        }
    }
}
#endif
