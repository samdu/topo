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
    /// The person's turns that were spoken, so their replies are read aloud and typed ones not.
    @State private var spokenTurns: Set<String> = []
    #if DEBUG
    /// The last spoken turn's nonce, for the title's debug report.
    @State private var spokenNonce: String?
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(turns: harness.turns, notice: harness.notice,
                               // Holding one of Topo's turns says it again, which is how a
                               // typed turn's reply — never read aloud as it lands — is heard.
                               replay: Replay(speaking: speaker.speaking,
                                              canSpeak: speaker.foreground,
                                              say: { speaker.speak($0) },
                                              stopSpeaking: { speaker.stop() }))
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
            .safeAreaInset(edge: .bottom) { composer }
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
                                                                error: harness.error, speaker: speaker.report))
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
                        Button("Diagnostics") { showDiagnostics = true }
                        Button("About Topo") { showAbout = true }
                        Divider()
                        Button("Sign out", role: .destructive) { harness.forget(); signIn.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showVocabulary) { VocabularyView() }
        }
        .task {
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
            defer { PushWake.remove() }
            await withDiscardingTaskGroup { group in
                group.addTask { try? await TurnPush.ensureSubscription() }
                await harness.answering(every: .seconds(5))
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
                    signIn.signOut()
                    return
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: voice.text) { _, text in if voice.owner == .chat, !text.isEmpty { draft = text } }
        .onChange(of: harness.turns.last?.ref) { _, _ in
            // A spoken question gets a spoken answer; a typed one stays quiet.
            guard readAloud, let last = harness.turns.last,
                  let asked = ReadAloud.spokenTurn(answeredBy: last, in: harness.turns, spoken: spokenTurns) else { return }
            spokenTurns.remove(asked)
            speaker.speak(last.text)
        }
        .onChange(of: scenePhase) { _, phase in
            // Speaking is foreground work; a backgrounded process submitting GPU commands is
            // killed. A microphone open when the scene goes is dropped, words and all: nobody is
            // holding it, so nothing said into it was meant.
            if phase != .active { speaker.stop(); voice.cancel(.chat) }
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
        let nonce = harness.willSend(heard)
        spokenTurns.insert(nonce)
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
