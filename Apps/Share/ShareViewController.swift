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
        let sheet = UIHostingController(rootView: ShareSheet(model: model, waits: true, cancel: { [weak self] in self?.cancel() },
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
