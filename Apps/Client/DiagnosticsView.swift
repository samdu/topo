#if os(iOS)
import SwiftUI

/// Why a turn did or did not go: the lease, the last CloudKit error, the last API answer, the
/// token. Opened by a long press on the title, or from the menu. Reads everything afresh each
/// time it appears and on Refresh; changes nothing.
struct DiagnosticsView: View {
    @Environment(Harness.self) private var harness
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
    }
}
#endif
