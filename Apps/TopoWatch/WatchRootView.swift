import SwiftUI
import TopoCore

/// The watch: the last of the transcript, and a button to say something.
///
/// It is a limb, not a mind. The button writes a turn of the person's into
/// the log; whichever device is primary reads it and answers. Nothing here
/// signs in, holds a token or runs a model.
struct WatchRootView: View {
    /// How much of the log a watch screen is worth. The whole transcript is
    /// in CloudKit either way; this is what a wrist can read.
    private static let latest = 20
    /// A wrist reads for a few seconds at a time, and the screen sleeps
    /// between. Slower than the television's, for the battery's sake.
    private static let refreshInterval = Duration.seconds(20)

    @State private var store = TranscriptStore(database: TopoCloudKit.database())

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Topo")
                .safeAreaInset(edge: .bottom) { talkButton }
        }
        .task { await store.refreshing(every: Self.refreshInterval) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .reading where store.turns.isEmpty:
            ProgressView()
        case .failed(let reason):
            note(reason)
        case .noLogYet:
            note("Nothing has been said yet. Press talk and it will be.")
        case .ready, .reading:
            if store.turns.isEmpty {
                note("Nothing has been said yet. Press talk and it will be.")
            } else {
                TranscriptView(turns: Array(store.turns.suffix(Self.latest)), notice: store.notice)
            }
        }
    }

    private func note(_ text: String) -> some View {
        VStack(spacing: 8) {
            ConnectedGlyph(isConnected: false).frame(width: 32, height: 32)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    /// Press to talk. watchOS has no Speech framework, so the system's own
    /// input controller is the microphone: it hears the person and hands
    /// back what they said, which goes into the log as their turn.
    private var talkButton: some View {
        VStack(spacing: 4) {
            if !store.outbox.isEmpty, !store.isSending {
                // Queued, not lost: this is the same turn again, under the
                // nonce it was first attempted with, so a send that
                // committed and lost its acknowledgement comes back rather
                // than being written twice.
                Button {
                    Task { await store.flush() }
                } label: {
                    Label(store.outbox.count == 1 ? "Send \"\(store.outbox[0])\" again"
                                                  : "Send \(store.outbox.count) unsent",
                          systemImage: "arrow.clockwise")
                        .lineLimit(1)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
            }
            TextFieldLink(prompt: Text("What did you forget?")) {
                Label(store.isSending ? "Sending…" : "Talk", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { spoken in
                Task { await store.send(spoken) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .disabled(store.isSending)
        }
        .padding(.horizontal, 4)
    }
}
