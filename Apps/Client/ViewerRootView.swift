#if os(iOS)
import SwiftUI
import TopoCore

/// A phone or pad that is not primary: the line saying what it is connected to, and the
/// transcript. It signs nothing in and holds no token.
struct ViewerRootView: View {
    private static let refreshInterval = Duration.seconds(10)

    @State private var store = TranscriptStore(database: TopoCloudKit.database())
    @State private var primary = PrimaryReader(database: TopoCloudKit.database())

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectedLine
                Divider()
                content
            }
            .navigationTitle("Topo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await store.refreshing(every: Self.refreshInterval) }
        .task {
            while !Task.isCancelled {
                await primary.refresh()
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
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
