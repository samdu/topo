import SwiftUI
import UIKit

/// Topo in another app's share sheet. It reads the one thing shared (`ShareIntake`), shows what
/// it is with a field for the person to say something about it, and on Send keeps it in the app
/// group (`ShareStore`) for the app to make a turn of when it next drains them, which is when it next comes to the front if nothing else asks sooner. It sends
/// nothing itself, reaches no network, and cannot bring Topo forward.
final class ShareViewController: UIViewController {
    private let model = ShareSheetModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = UIHostingController(rootView: ShareSheet(model: model, cancel: { [weak self] in self?.cancel() },
                                                             send: { [weak self] in self?.send() }))
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)

        let providers = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        Task { await model.read(providers) }
    }

    private func cancel() {
        model.discard()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func send() {
        guard model.keep() else { return }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareSheet: View {
    @Bindable var model: ShareSheetModel
    let cancel: () -> Void
    let send: () -> Void
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
                        Label(Self.words(for: item), systemImage: Self.symbol(for: item.kind))
                            .lineLimit(4)
                    } footer: {
                        Text("Topo reads it the next time you open Topo.")
                    }
                }
            }
            .navigationTitle("Topo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send).disabled(!ready || model.noteTooLong)
                }
            }
            .onChange(of: ready) { _, ready in writing = ready }
        }
    }

    private var ready: Bool {
        if case .ready = model.state { return true }
        return false
    }

    static func symbol(for kind: Share.Kind) -> String {
        switch kind {
        case .text, .prompt, .task: "text.quote"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    static func words(for item: ShareIntake.Item) -> String {
        switch item.kind {
        case .text, .link, .prompt, .task: item.text ?? ""
        case .image, .file:
            [item.file?.lastPathComponent, item.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }
}
