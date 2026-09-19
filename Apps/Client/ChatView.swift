#if os(iOS)
import SwiftUI
import TopoAuth
import TopoCore
import TopoTurn

/// Single-device chat: the transcript from the log, a field to type in, a mic to dictate with.
struct ChatView: View {
    @Environment(Harness.self) private var harness
    @Environment(SignIn.self) private var signIn
    @Environment(RoleSelector.self) private var roleSelector
    @Environment(Memory.self) private var memory
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""
    @AppStorage("firstRunAnswered") private var answered = false
    @Environment(VoiceInput.self) private var voice
    @Environment(Speaker.self) private var speaker
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("readAloud") private var readAloud = true
    @State private var draft = ""
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var showVocabulary = false
    /// Where the memory's folder lives, and the control that moves it. An item here until the
    /// settings sheet exists, and that sheet's Memory section when it does.
    @State private var showMemory = false
    /// The offer card's answer, once and for good: Choose folder or Not now.
    @AppStorage("memoryOfferAnswered") private var memoryOfferAnswered = false
    #if DEBUG
    /// The last spoken turn's nonce, for the title's debug report.
    @State private var spokenNonce: String?
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(turns: harness.turns, notice: harness.notice,
                               // Holding one of Topo's turns says it again, which is how a
                               // typed turn's reply — never read aloud as it lands — is heard.
                               replay: Replay(speaking: speaker.speaking,
                                              canSpeak: speaker.voice.ready,
                                              say: { speaker.speak($0) },
                                              stopSpeaking: { speaker.stop() }),
                               // Holding one of their own turns puts its words back into the
                               // draft. The log is append-only, so this edits what is said next
                               // and never the turn that was said.
                               actions: TurnActions(edit: { draft = $0.text }))
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
                    .padding(.bottom, 8)
                }
                if let error = harness.error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 8)
                }
                if let info = harness.info {
                    Text(info).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
                }
                if harness.hasWaiting {
                    // The line stopped on a failure; what was said is kept and goes again from here.
                    Button {
                        Task { await harness.retry() }
                    } label: {
                        Label(harness.waiting.count == 1 ? "Send \"\(harness.waiting[0])\" again"
                                                         : "Send \(harness.waiting.count) waiting",
                              systemImage: "arrow.clockwise")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    .padding(.bottom, 8)
                }
            }
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
                    }
                    composer
                }
            }
            .navigationTitle("Topo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Topo").font(.headline)
                        .onLongPressGesture { showDiagnostics = true }
                        .accessibilityHint("Long press for diagnostics")
                        #if DEBUG
                        // What the spoken-turn UI test decodes: the last spoken turn, its reply,
                        // and what the speaker did with it, as JSON (`DebugRun.ChatReport`).
                        .accessibilityIdentifier(DebugRun.chatReportIdentifier)
                        .accessibilityValue(DebugRun.chatReport(spoken: spokenNonce, turns: harness.turns,
                                                                error: harness.error, speaker: speaker.report,
                                                                voice: speaker.voice.state))
                        #endif
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        @Bindable var harness = harness
                        Picker("Model", selection: $harness.model) {
                            ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        Toggle("Read replies aloud", isOn: $readAloud)
                        Button("Vocabulary") { showVocabulary = true }
                        Button("Memory") { showMemory = true }
                        Button("Diagnostics") { showDiagnostics = true }
                        Button("About Topo") { showAbout = true }
                        Divider()
                        // The reply in the ear goes with the login: a reply still being read
                        // would otherwise carry on, holding the process open, for an account the
                        // app has just let go of.
                        Button("Sign out", role: .destructive) {
                            speaker.stop()
                            harness.forget()
                            // The memory is the person's and stays in their iCloud; the copy of
                            // it on this phone goes with the login.
                            memory.forget()
                            signIn.signOut()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showVocabulary) { VocabularyView() }
            .sheet(isPresented: $showMemory) { MemoryView() }
        }
        .task {
            // The mirror runs on every pass of the loop below, which is what makes the folder
            // current with no push and no turn. It is installed before the first turn of all,
            // not after it: the first-run answer is a turn like any other, and a screen that
            // installed this after sending would leave that one turn's work for whatever cue
            // came next. What a revision's push wakes is put up with the login rather than with
            // this screen (`MemoryWake`, from `TopoApp`).
            harness.onPass = { [memory] in await memory.sync() }
            defer { harness.onPass = nil }
            await harness.refresh()
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
        .onChange(of: voice.text) { _, text in if voice.owner == .chat, !text.isEmpty { draft = text } }
        .onChange(of: scenePhase) { _, phase in
            // A microphone open when the scene goes is dropped, words and all: nobody is holding
            // it, so nothing said into it was meant. A reply plays on — that is what the hold is
            // for — and the press that starts the next one is what stops it.
            if phase != .active { voice.cancel(.chat) }
        }
        .onDisappear { voice.cancel(.chat) }
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
        draft = ""
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
        let nonce = harness.willSend(heard)
        if speaker.awaitReply(nonce, readAloud: readAloud).spoken { harness.markSpoken(nonce) }
        #if DEBUG
        spokenNonce = nonce
        #endif
        await harness.retry()
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Say something", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Image(systemName: voice.listening && voice.owner == .chat ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.title)
                // Dimmed while a press would be refused: the microphone denied, or an ear that
                // is not resident yet. The diagnostics `speech` row is what says which.
                .foregroundStyle(voice.canListen ? Theme.teal : .secondary)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                    Task { await micPressed(down) }
                }
                .accessibilityLabel(voice.handsFree ? "Listening; press to send" : voice.listening ? "Listening; release to send" : "Hold to talk")
                #if DEBUG
                // What the UI test decodes after a press: the counters, the branch it took, and
                // what the microphone delivered, as JSON (`VoiceInput.Report`). A debug build
                // only, so VoiceOver on a release build hears the label alone.
                .accessibilityValue(voice.debugReport)
                #endif
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Theme.teal)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        voice.cancel(.chat)
        let text = draft
        draft = ""
        Task { await harness.send(text) }
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
