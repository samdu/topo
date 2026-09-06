#if os(iOS)
import SwiftUI

/// Who to thank: the mark, the version, where the name comes from, and what
/// `THIRD-PARTY` says. The list is read from the file in the bundle rather
/// than written here, so a licence added to the file shows up on the screen
/// and nobody has to remember both.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let acknowledgements = Acknowledgements.bundled()

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }
                Section("The name") {
                    Text("Topo is Aquaman's octopus sidekick, first seen in Adventure Comics #229 (1956), written by Jack Miller and drawn by Ramona Fradon. The product is the octopus: the mind is the head and every device is an arm.")
                }
                if let acknowledgements {
                    Section("Acknowledgements") {
                        ForEach(acknowledgements.note, id: \.self) { paragraph in
                            Text(paragraph).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(acknowledgements.entries) { entry in
                        Section(entry.name) {
                            ForEach(entry.fields) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.key).font(.caption).foregroundStyle(.secondary)
                                    Text(field.value).textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    Section("Acknowledgements") {
                        Text("THIRD-PARTY is missing from this build.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            OctopusMark().frame(width: 88, height: 88)
            Text("Topo").font(.title2.weight(.semibold))
            Text(Self.version).font(.footnote).foregroundStyle(.secondary)
            Text("Open source under the GPL, and not for profit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 8)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(marketing) (\(build))"
    }
}
#endif
