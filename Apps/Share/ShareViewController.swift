import SwiftUI
import UIKit

/// Topo in another app's share sheet. It reads the one thing shared (`ShareIntake`), shows what
/// it is with a field for the person to say something about it, and on Send keeps it in the app
/// group (`ShareStore`) for the app to make a turn of when it next comes to the front. It sends
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

/// What the sheet shows and does: the thing shared once it is read, why it was refused if it
/// was, and the note.
@MainActor
@Observable
final class ShareSheetModel {
    enum State: Equatable {
        case reading
        case ready(ShareIntake.Item)
        case refused(ShareRefusal)
    }

    private(set) var state: State = .reading
    var note = ""
    private let store: ShareStore?
    private var scratch: URL?

    init(store: ShareStore? = ShareStore.shared()) {
        self.store = store
    }

    func read(_ providers: [NSItemProvider]) async {
        guard let store, let door = store.door() else { return state = .refused(.signedOut) }
        guard let choice = ShareIntake.choice(among: providers) else { return state = .refused(.nothing) }
        if choice.kind == .image || choice.kind == .file, !door.files { return state = .refused(.anotherPhone) }
        do {
            let scratch = try store.scratch()
            self.scratch = scratch
            state = .ready(try await ShareIntake.item(from: providers, into: scratch))
        } catch let refusal as ShareRefusal {
            discard()
            state = .refused(refusal)
        } catch {
            discard()
            state = .refused(.failed)
        }
    }

    /// Keeps the share, and answers whether it was kept; a refusal is shown in its place.
    func keep() -> Bool {
        guard let store, case .ready(let item) = state else { return false }
        let share = Share(nonce: UUID().uuidString, time: Date(), kind: item.kind, note: String(note.prefix(Share.noteLimit)),
                          text: item.text, file: item.file?.lastPathComponent, bytes: item.bytes)
        do {
            try store.keep(share, attachment: item.file)
        } catch {
            discard()
            state = .refused(error)
            return false
        }
        discard()
        return true
    }

    func discard() {
        if let scratch { store?.discard(scratch) }
        scratch = nil
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
                case .ready(let item):
                    Section {
                        TextField("Say something about it", text: $model.note, axis: .vertical)
                            .lineLimit(3...8)
                            .focused($writing)
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
                    Button("Send", action: send).disabled(!ready)
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
        case .text: "text.quote"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    static func words(for item: ShareIntake.Item) -> String {
        switch item.kind {
        case .text, .link: item.text ?? ""
        case .image, .file:
            [item.file?.lastPathComponent, item.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }
}
