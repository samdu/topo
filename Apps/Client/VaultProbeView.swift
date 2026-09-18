#if DEBUG && os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The probe's screen, opened from the settings sheet in a debug build. It says where the bookmark
/// resolves to on this launch, and gives the three buttons whose answers are the thing being
/// probed: Read (list the folder and read a file, waiting for one iCloud Drive has evicted),
/// Write (a coordinated write of `topo-probe.md`), Forget (drop the bookmark).
///
/// It is a probe and not a setting: nothing here reaches the vault, the mirror or the memory's
/// home, and what a run says is read off the screen by a person holding the phone.
struct VaultProbeView: View {
    @State private var probe = VaultProbe()
    @State private var picking = false
    @State private var fileName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch probe.state {
                    case .none:
                        Text("No folder picked.").foregroundStyle(.secondary)
                    case .home(let path, let stale):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(path).font(.footnote.monospaced()).textSelection(.enabled)
                            Text(stale ? "stale, made again" : "resolved").font(.caption)
                                .foregroundStyle(stale ? .orange : .secondary)
                        }
                    case .lost(let reason):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lost").foregroundStyle(.red)
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("The home, as the bookmark resolves on this launch")
                }

                Section {
                    Button("Pick a folder…") { picking = true }
                    TextField("File to read (empty: the first)", text: $fileName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Read") { Task { await probe.read(named: fileName) } }
                        .disabled(probe.busy || !hasHome)
                    Button("Write topo-probe.md") { Task { await probe.write() } }
                        .disabled(probe.busy || !hasHome)
                    Button("Forget", role: .destructive) { probe.forget() }
                        .disabled(probe.busy)
                }

                if !probe.report.isEmpty {
                    Section {
                        ForEach(Array(probe.report.enumerated()), id: \.offset) { line in
                            Text(line.element).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    } header: {
                        Text("What the last run did")
                    }
                }
            }
            .navigationTitle("Probe iCloud Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if probe.busy { ProgressView() } }
            .sheet(isPresented: $picking) {
                FolderPicker(startingAt: VaultProbe.obsidianDirectory()) { url in
                    if let url { probe.keep(url) }
                }
            }
            .onAppear { probe.load() }
        }
    }

    private var hasHome: Bool {
        if case .home = probe.state { return true }
        return false
    }
}

/// `UIDocumentPickerViewController` in `.open` mode for a folder, which is the whole of the
/// permission story: what the person picks is what this app may reach, and no entitlement of ours
/// asks for iCloud Drive or for Obsidian's container. `startingAt` is a hint the picker takes or
/// leaves.
struct FolderPicker: UIViewControllerRepresentable {
    var startingAt: URL?
    var picked: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.directoryURL = startingAt
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let picked: (URL?) -> Void

        init(picked: @escaping (URL?) -> Void) { self.picked = picked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            picked(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            picked(nil)
        }
    }
}
#endif
