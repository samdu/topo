#if os(iOS)
import SwiftUI
import TopoAuth

/// Why a turn did or did not go: the lease, the last CloudKit error, the last API answer, the
/// token, whether the ear's and the voice's models are resident, when the memory's folder was
/// last in step with the store, what the vault's `look.json` said, and where the guest's rootfs
/// stands. Opened by a long press on
/// the badge, or from the settings sheet it opens. Reads everything afresh each time it appears
/// and on Refresh; changes nothing.
struct DiagnosticsView: View {
    @Environment(Harness.self) private var harness
    @Environment(VoiceInput.self) private var voice
    @Environment(Speaker.self) private var speaker
    @Environment(Memory.self) private var memory
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(String, String)] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { Task { await load() } }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        rows = await harness.diagnostics().rows
            + [("speech", voice.ear.summary), ("voice", speaker.voice.summary),
               ("memory", memory.summary), ("look", memory.lookReading.summary),
               ("userland", Userland.shared.summary),
               ("guest token", GuestTokenSummary.of { try KeychainTokenStore.guest.load() })]
    }
}

/// Whether the guest's long-lived token is held, and for how long, with nothing of its value:
/// Claude Code answers on the ordinary token without it (`GuestCredential`), so a turn answered
/// does not say the second authorization of a sign-in landed, and this does.
enum GuestTokenSummary {
    static func of(now: Date = Date(), _ load: () throws -> Tokens?) -> String {
        do {
            guard let held = try load() else { return "none held; Claude Code runs on the ordinary token" }
            let days = Int((held.expiresAt.timeIntervalSince(now) / 86_400).rounded(.down))
            return held.expiresAt > now ? "held, \(days) days left" : "held, expired"
        } catch {
            return "unreadable: \(error)"
        }
    }
}
#endif
