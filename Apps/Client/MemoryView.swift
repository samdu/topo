#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The Memory section: where the vault folder is, and the one control that moves it.
///
/// It lives behind an item in the chat's overflow menu until the settings sheet exists, and moves
/// into that sheet's Memory section when it does.
struct MemoryView: View {
    @Environment(Memory.self) private var memory
    @Environment(\.dismiss) private var dismiss
    @AppStorage("memoryOfferAnswered") private var offerAnswered = false
    @State private var picking = false
    @State private var confirmingComeHome = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(memory.homeSummary)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(isLost ? .red : .primary)
                    if isLost {
                        Text("Pick the folder again, or keep the memory on this iPhone. Nothing "
                             + "syncs until one of those.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Where the memory lives")
                }

                Section {
                    Button("Keep memory in Obsidian…") { picking = true }
                        .disabled(memory.moving)
                    if memory.home.folder != nil || isLost {
                        Button("Keep memory on this iPhone") {
                            confirmingComeHome = true
                        }
                        .disabled(memory.moving)
                    }
                    if memory.moving {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Moving the memory…").font(.footnote)
                        }
                    }
                } footer: {
                    Text("Obsidian opens a vault in iCloud Drive, on this phone and on your Macs. "
                         + "The memory itself does not move: the revisions stay in your iCloud, "
                         + "and only the folder they are mirrored into changes.")
                }

                if let error = memory.moveError {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    } header: {
                        Text("The last move")
                    }
                }

                if let stranded = memory.stranded {
                    Section {
                        Text("The old copy is still \(stranded.isLocal ? "on this iPhone" : "in iCloud Drive").")
                            .font(.footnote)
                        Text(stranded.names.prefix(10).joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Remove the old copy", role: .destructive) {
                            Task { await memory.removeStranded() }
                        }
                    } header: {
                        Text("Left behind")
                    } footer: {
                        Text("The memory has moved; this is only the old folder going.")
                    }
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $picking) {
                FolderPicker(startingAt: VaultHome.obsidianDirectory()) { url in
                    guard let url else { return }
                    // The card has been answered either way once the picker has been through.
                    offerAnswered = true
                    Task { await memory.keepInICloudDrive(url) }
                }
            }
            .confirmationDialog("Keep memory on this iPhone?", isPresented: $confirmingComeHome,
                                titleVisibility: .visible) {
                Button("Keep memory on this iPhone") { Task { await memory.keepOnThisPhone() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The files come back into Topo's own folder, where Files shows them. "
                     + "Obsidian stops seeing them.")
            }
        }
    }

    private var isLost: Bool {
        if case .lost = memory.home { return true }
        return false
    }
}

/// The card above the composer, once: the mind saying its memory could live where Obsidian opens
/// it. The phone harness has no tools, so this is a line in the chat rather than something the
/// model does.
struct MemoryOfferCard: View {
    var choose: () -> Void
    var notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your memory can live in iCloud Drive, where Obsidian opens it")
                .font(.footnote)
            HStack(spacing: 12) {
                Button("Choose folder", action: choose).buttonStyle(.borderedProminent)
                Button("Not now", action: notNow).buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
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
