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
    @State private var typing = false
    /// The nonce of the draft on its way to the log; the draft row shows it as sending until
    /// the turn with that nonce lands, then clears.
    @State private var sentNonce: String?
    @State private var showDiagnostics = false
    @State private var showSettings = false
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
                                              stopSpeaking: { speaker.stop() }),
                               actions: TurnActions(edit: { turn in draft = turn.text; typing = true }),
                               // Typing, and a live caption, are the person's next turn in
                               // progress, drawn where it will land.
                               draft: Draft(text: $draft, active: $typing, sending: sentNonce != nil, send: send))
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
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { badge } }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
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
        // The keyboard mutes the microphone: a hands-free session ends, and what it heard so far
        // stays in the draft to be finished by hand.
        .onChange(of: typing) { _, typing in if typing { voice.cancel(.chat) } }
        .onChange(of: harness.turns.last?.ref) { _, _ in
            // The draft on its way has landed: the log shows it now, so the row goes.
            if let sentNonce, harness.turns.contains(where: { $0.nonce == sentNonce }) {
                draft = ""
                self.sentNonce = nil
            }
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

    private var badge: some View {
        TopoBadge(status: .primary,
                  openSettings: { showSettings = true },
                  openDiagnostics: { showDiagnostics = true })
            #if DEBUG
            // What the spoken-turn UI test decodes: the last spoken turn, its reply, and what
            // the speaker did with it, as JSON (`DebugRun.ChatReport`).
            .accessibilityIdentifier(DebugRun.chatReportIdentifier)
            .accessibilityValue(DebugRun.chatReport(spoken: spokenNonce, turns: harness.turns,
                                                    error: harness.error, speaker: speaker.report,
                                                    voice: speaker.voice.state))
            #endif
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
        draft = heard
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        #if DEBUG
        if DebugRun.keepsSpoken() {
            DebugRun.say("heard, not sent: \(heard)")
            return
        }
        #endif
        let nonce = harness.willSend(heard)
        spokenTurns.insert(nonce)
        sentNonce = nonce
        #if DEBUG
        spokenNonce = nonce
        #endif
        await harness.retry()
    }

    private var composer: some View {
        Composer(typing: $typing,
                 mic: .init(canListen: voice.canListen,
                            listening: voice.listening && voice.owner == .chat,
                            handsFree: voice.handsFree),
                 micPressed: { down in Task { await micPressed(down) } },
                 micReport: micReport)
    }

    /// What the UI test decodes after a press: the counters, the branch it took, and what the
    /// microphone delivered, as JSON (`VoiceInput.Report`). A debug build only, so VoiceOver on
    /// a release build hears the label alone.
    private var micReport: String? {
        #if DEBUG
        voice.debugReport
        #else
        nil
        #endif
    }

    private func send() {
        voice.cancel(.chat)
        typing = false
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The words stay in the draft row, as sending, until the turn is in the log.
        sentNonce = harness.willSend(draft)
        Task { await harness.retry() }
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
