#if os(iOS)
import SwiftUI

/// The mark in the navigation bar, at the trailing edge where a back button is not: a small
/// cabochon carrying the octopus, coloured by what this device is. A tap opens the settings;
/// a hold, the diagnostics.
struct TopoBadge: View {
    var status = Status.primary
    var openSettings: () -> Void = {}
    var openDiagnostics: () -> Void = {}

    /// What the glass says without a word: teal for the primary, the secondary's mauve for a
    /// limb of one, and drained of colour when the mind cannot be reached.
    enum Status {
        case primary, limb, unreachable
    }

    var body: some View {
        Button(action: openSettings) {
            StainedGlass()
                .hueRotation(.degrees(status == .limb ? 100 : 0))
                .saturation(status == .unreachable ? 0 : 1)
                .frame(width: 30, height: 30)
                .overlay {
                    OctopusMark(color: .white)
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in openDiagnostics() })
        .accessibilityLabel("Topo, \(label)")
        .accessibilityHint("Settings; hold for diagnostics")
    }

    private var label: String {
        switch status {
        case .primary: "primary"
        case .limb: "limb"
        case .unreachable: "unreachable"
        }
    }
}

#if DEBUG
#Preview("Badge") {
    @Previewable @State var status = TopoBadge.Status.primary
    VStack(spacing: 0) {
        NavigationStack {
            TranscriptView(turns: PreviewTurns.long, origin: PreviewTurns.origin)
                .navigationTitle("")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { TopoBadge(status: status) } }
        }
        Divider()
        Picker("Status", selection: $status) {
            Text("Primary").tag(TopoBadge.Status.primary)
            Text("Limb").tag(TopoBadge.Status.limb)
            Text("Unreachable").tag(TopoBadge.Status.unreachable)
        }
        .pickerStyle(.segmented)
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
    }
}
#endif
#endif
