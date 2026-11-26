import SwiftUI
import UIKit

/// Draws `content` in a window of its own over the scene's windows, so it stands over a sheet the
/// system presents on the app's window (`WebAuth`'s browser), which no view in the app's own
/// window can be drawn over. The window is the scene's size and lays the content out in the
/// scene's safe area as any window does, but takes a touch only where `takes` says, in the
/// window's points: every other touch falls through to the windows under it, the sheet among
/// them. Nil content, or this view being torn down, takes the window away; the view merely
/// leaving its window under a presentation does not.
///
/// SwiftUI presents nothing over a presentation it did not make (`.overlay`, `.sheet` and
/// `.fullScreenCover` all join the window's own presentation stack, under the system's sheet), and
/// the system's sheet takes no accessory, so the window's level is the mechanism. A window's
/// `hitTest` answering nil is UIKit's way of passing a touch on to the window under it.
struct AboveSheets<Content: View>: UIViewRepresentable {
    let content: Content?
    let takes: @MainActor (CGPoint) -> Bool

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.show(content.map { AnyView($0) }, takes: takes)
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) {
        anchor.show(nil, takes: { _ in false })
    }

    /// The view in the app's own window that finds the scene and holds the window above it. The
    /// scene is that of the window it was last in: a sheet presented over the screen can take the
    /// screen's views out of the window, which is the moment the window above is wanted.
    final class Anchor: UIView {
        private(set) var above: AboveSheetsWindow?
        private weak var scene: UIWindowScene?
        private var wanted: (view: AnyView, takes: @MainActor (CGPoint) -> Bool)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let found = window?.windowScene { scene = found }
            place()
        }

        func show(_ view: AnyView?, takes: @escaping @MainActor (CGPoint) -> Bool) {
            wanted = view.map { ($0, takes) }
            place()
        }

        private func place() {
            guard let wanted, let scene else {
                above?.isHidden = true
                above = nil
                return
            }
            let held = above ?? AboveSheetsWindow(windowScene: scene)
            above = held
            held.hold(wanted.view, takes: wanted.takes)
        }
    }
}

/// The window `AboveSheets` draws in: the scene's size, one level over the app's, under the
/// keyboard and the system's alerts. It never becomes key, so the keyboard, and the key window
/// the browser's sheet is anchored on (`WebAuth.presentationAnchor`), stay the app's.
final class AboveSheetsWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var takes: @MainActor (CGPoint) -> Bool = { _ in false }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        host.view.backgroundColor = .clear
        backgroundColor = .clear
        rootViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeKey: Bool { false }

    /// Draws `view`, taking the touches `takes` says are its.
    func hold(_ view: AnyView, takes: @escaping @MainActor (CGPoint) -> Bool) {
        host.rootView = view
        self.takes = takes
        isHidden = false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard takes(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
