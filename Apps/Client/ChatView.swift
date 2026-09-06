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
    /// The person's turns that were spoken, so their replies are read aloud and typed ones not.
    @State private var spokenTurns: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(turns: harness.turns, notice: harness.notice)
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        @Bindable var harness = harness
                        Picker("Model", selection: $harness.model) {
                            ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        Toggle("Read replies aloud", isOn: $readAloud)
                        Button("Diagnostics") { showDiagnostics = true }
                        Divider()
                        Button("Sign out", role: .destructive) { harness.forget(); signIn.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
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
            // write into the log.
            await harness.answering(every: .seconds(5))
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
        .onChange(of: voice.unsent) { _, _ in
            // The recogniser ended the session itself; what it heard goes as a spoken turn.
            guard let heard = voice.takeUnsent(for: .chat) else { return }
            Task { await sendSpoken(heard) }
        }
        .onChange(of: harness.turns.last?.ref) { _, _ in
            // A spoken question gets a spoken answer; a typed one stays quiet.
            guard readAloud, let last = harness.turns.last, last.role == .assistant,
                  let asked = last.parents.first.flatMap({ ref in harness.turns.first { $0.ref == ref } }),
                  spokenTurns.remove(asked.nonce) != nil else { return }
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
        spokenTurns.insert(harness.willSend(heard))
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
                .foregroundStyle(voice.denied ? .secondary : Theme.teal)
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {} onPressingChanged: { down in
                    Task { await micPressed(down) }
                }
                .accessibilityLabel(voice.handsFree ? "Listening; press to send" : voice.listening ? "Listening; release to send" : "Hold to talk")
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
#endif
