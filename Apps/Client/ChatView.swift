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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(harness.turns) { turn in
                            TurnBubble(turn: turn).id(turn.ref)
                        }
                        if harness.busy { ProgressView().padding(.leading) }
                        if let error = harness.error {
                            Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: harness.turns.count) { _, _ in
                    if let last = harness.turns.last { withAnimation { proxy.scrollTo(last.ref, anchor: .bottom) } }
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

struct TurnBubble: View {
    let turn: Turn
    var body: some View {
        HStack {
            if turn.role == .person { Spacer(minLength: 48) }
            Text(turn.text)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(turn.role == .person ? Theme.teal.opacity(0.18) : Color.secondary.opacity(0.12)))
                .textSelection(.enabled)
            if turn.role == .assistant { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }
}
#endif
