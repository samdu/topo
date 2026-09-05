#if os(iOS)
import SwiftUI
import TopoCore

/// A phone or pad that is not primary: the line saying what it is connected to, and the
/// transcript. It signs nothing in and holds no token.
struct ViewerRootView: View {
    private static let refreshInterval = Duration.seconds(10)

    @Environment(RoleSelector.self) private var roleSelector
    @State private var store = TranscriptStore(database: TopoCloudKit.database())
    @State private var primary = PrimaryReader(database: TopoCloudKit.database())
    @State private var confirmingTakeover = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectedLine
                Divider()
                content
                if let taking = roleSelector.taking {
                    HStack(spacing: 8) { ProgressView(); Text(taking) }
                        .font(.footnote).padding(.bottom, 8)
                } else if let trouble = roleSelector.trouble {
                    Text(trouble).font(.footnote).foregroundStyle(.red).padding(.horizontal).padding(.bottom, 8)
                }
            }
            .navigationTitle("Topo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Make this device the primary…") { confirmingTakeover = true }
                            .disabled(roleSelector.taking != nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Make this device the primary?", isPresented: $confirmingTakeover, titleVisibility: .visible) {
                Button("Make this device the primary", role: .destructive) {
                    Task { await roleSelector.takePrimary() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(takeoverWarning)
            }
        }
        .task { await store.refreshing(every: Self.refreshInterval) }
        .task {
            while !Task.isCancelled {
                await primary.refresh()
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
    }

    /// Plain words for what the takeover does: the other device stops answering.
    private var takeoverWarning: String {
        let other = primary.lease?.holder.rawValue ?? "The device that is primary now"
        return "\(other) stops answering, and you sign in with Claude here. If it is only asleep, this waits up to ten seconds for it first."
    }

    private var connectedLine: some View {
        HStack(spacing: 10) {
            ConnectedGlyph(isConnected: primary.isFresh).frame(width: 22, height: 22)
            if let holder = primary.lease?.holder {
                Text(primary.isFresh ? "Connected to \(holder.rawValue)" : "\(holder.rawValue) is primary; it is asleep right now")
            } else {
                Text("Nothing is primary right now")
            }
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .reading where store.turns.isEmpty:
            VStack { Spacer(); ProgressView(); Spacer() }
        case .failed(let message):
            VStack { Spacer(); Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(); Spacer() }
        case .noLogYet:
            VStack { Spacer(); ViewerPlaceholder(); Spacer() }
        case .ready, .reading:
            if store.turns.isEmpty {
                VStack { Spacer(); ViewerPlaceholder(); Spacer() }
            } else {
                TranscriptView(turns: store.turns, notice: store.notice)
            }
        }
    }
}
#endif
