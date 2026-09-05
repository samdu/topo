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
    @State private var draft = ""
    @State private var dictation = Dictation()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TranscriptView(turns: harness.turns, notice: harness.notice)
                if harness.busy { ProgressView().padding(.bottom, 8) }
                if let error = harness.error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 8)
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Topo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        @Bindable var harness = harness
                        Picker("Model", selection: $harness.model) {
                            ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        Divider()
                        Button("Sign out", role: .destructive) { harness.forget(); signIn.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await harness.refresh()
            // The first-run answer is the first turn, once and only if nothing is in the log yet.
            if harness.turns.isEmpty, !firstRunAnswer.isEmpty, !harness.busy {
                await harness.send(firstRunAnswer)
            }
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
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || harness.busy)
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
