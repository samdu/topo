import SwiftUI
import TopoCore

/// The television: the transcript on the big screen, and the line saying
/// what it is connected to.
///
/// A viewer and nothing else. The TV build never offers to be primary — it
/// reads the lease to name the device that is, and writes nothing at all:
/// no claim, no heartbeat, no turn. tvOS suspends third-party apps, so it
/// could not hold a lease it claimed.
struct TVRootView: View {
    /// A wall screen shows what is current. Subscriptions are the design's
    /// answer and are not wired yet, so it re-reads on a timer.
    private static let refreshInterval = Duration.seconds(15)

    @State private var store = TranscriptStore(database: TopoCloudKit.database())
    @State private var primary = PrimaryReader(database: TopoCloudKit.database())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            connectedLine
            Divider()
            content
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                await primary.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private var connectedLine: some View {
        HStack(spacing: 16) {
            ConnectedGlyph(isConnected: primary.isFresh).frame(width: 34, height: 34)
            if primary.isFresh, let holder = primary.lease?.holder {
                Text("Connected to \(holder.rawValue)")
            } else {
                Text("Nothing is primary right now")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 20)
        // The same column the turns are in, so the line sits over them.
        .frame(maxWidth: Metrics.maximumLineWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .reading where store.turns.isEmpty:
            centred { ProgressView() }
        case .failed(let message):
            centred {
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .noLogYet:
            centred { ViewerPlaceholder() }
        case .ready, .reading:
            if store.turns.isEmpty {
                centred { ViewerPlaceholder() }
            } else {
                TranscriptView(turns: store.turns, notice: store.notice)
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }
}
