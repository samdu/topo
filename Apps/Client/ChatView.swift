#if os(iOS)
import SwiftUI
import TopoAuth
import TopoCore
import TopoTurn

/// Single-device chat: the transcript from the log, a field to type in, a mic to dictate with.
struct ChatView: View {
    @Environment(Harness.self) private var harness
    @Environment(SignIn.self) private var signIn
    @AppStorage("firstRunAnswer") private var firstRunAnswer = ""
    @AppStorage("firstRunAnswered") private var answered = false
    @State private var draft = ""
    @State private var dictation = Dictation()
    @State private var showDiagnostics = false

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
        .onChange(of: dictation.text) { _, text in if !text.isEmpty { draft = text } }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Say something", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Button {
                Task { await dictation.toggle() }
            } label: {
                Image(systemName: dictation.listening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.title)
                    .foregroundStyle(dictation.denied ? .secondary : Theme.teal)
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Theme.teal)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        dictation.stop()
        let text = draft
        draft = ""
        Task { await harness.send(text) }
    }
}
#endif
