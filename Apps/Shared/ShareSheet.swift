#if os(iOS)
import SwiftUI

/// The sheet a share is sent from: what was shared or picked, a field to say something about it,
/// Cancel and Send. The share extension draws it over what another app handed over, and the
/// composer's `+` over what the person picked on this phone; `waits` says which footer is true,
/// since a share from the extension is read when Topo next comes to the front and one from the
/// composer at once.
struct ShareSheet: View {
    @Bindable var model: ShareSheetModel
    var waits: Bool
    /// The marks beside what was shared. The app hands the look's in; the extension, which has
    /// no look, draws the defaults.
    var marks = Marks()
    let cancel: () -> Void
    let send: () -> Void

    struct Marks {
        var text = "text.quote"
        var link = "link"
        var image = "photo"
        var file = "doc"

        func symbol(for kind: Share.Kind) -> String {
            switch kind {
            case .text, .prompt, .task, .timer: text
            case .link: link
            case .image: image
            case .file: file
            }
        }
    }
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .reading:
                    ProgressView()
                case .refused(let refusal):
                    Text(refusal.words)
                case .sent:
                    ProgressView()
                case .ready(let item):
                    Section {
                        TextField("Say something about it", text: $model.note, axis: .vertical)
                            .lineLimit(3...8)
                            .focused($writing)
                    } footer: {
                        if model.noteTooLong { Text("That is a longer note than Topo takes (\(Share.noteLimit) characters).") }
                    }
                    Section {
                        Label(Self.words(for: item), systemImage: marks.symbol(for: item.kind))
                            .lineLimit(4)
                            .accessibilityIdentifier("share-item")
                    } footer: {
                        Text(waits ? "Topo reads it the next time you open Topo." : "Topo reads it now.")
                    }
                }
            }
            .navigationTitle("Topo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("share-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send).disabled(!ready || model.noteTooLong).accessibilityIdentifier("share-send")
                }
            }
            // The field takes focus as the thing is ready: read by the extension once the
            // sheet is up, or ready already when the app puts the sheet up.
            .onChange(of: ready, initial: true) { _, ready in writing = ready }
        }
    }

    private var ready: Bool {
        if case .ready = model.state { return true }
        return false
    }

    static func words(for item: ShareIntake.Item) -> String {
        switch item.kind {
        case .text, .link, .prompt, .task, .timer: item.text ?? ""
        case .image, .file:
            [item.file?.lastPathComponent, item.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }
}
#endif
