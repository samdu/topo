import SwiftUI
import UIKit

/// Draws `content` in a window of its own over the scene's windows, so it stands over a sheet the
/// system presents on the app's window (`WebAuth`'s browser), which no view in the app's own
/// window can be drawn over. The window is the size of what it holds at its ideal height, at
/// `top` points under the app window's safe area and centred, `width` points wide at most: a touch
/// anywhere else reaches the sheet under it, so nothing of the sheet is taken from the person but
/// what the content covers. Nil content, or this view leaving the screen, takes the window away.
///
/// SwiftUI presents nothing over a presentation it did not make (`.overlay`, `.sheet` and
/// `.fullScreenCover` all join the window's own presentation stack, under the system's sheet), and
/// the system's sheet takes no accessory, so the window's level is the mechanism.
struct AboveSheets<Content: View>: UIViewRepresentable {
    let content: Content?
    let top: CGFloat
    let width: CGFloat

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.show(content.map { AnyView($0.fixedSize(horizontal: false, vertical: true)) }, top: top, width: width)
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) {
        anchor.show(nil, top: 0, width: 0)
    }

    /// The view in the app's own window that finds the scene and holds the window above it. The
    /// scene and the safe area are those of the window it was last in: a sheet presented over the
    /// screen can take the screen's views out of the window, which is the moment the window above
    /// is wanted.
    final class Anchor: UIView {
        private(set) var above: AboveSheetsWindow?
        private weak var scene: UIWindowScene?
        private var inset: CGFloat = 0
        private var wanted: (view: AnyView, top: CGFloat, width: CGFloat)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, let found = window.windowScene {
                scene = found
                inset = window.safeAreaInsets.top
            }
            place()
        }

        func show(_ view: AnyView?, top: CGFloat, width: CGFloat) {
            wanted = view.map { ($0, top, width) }
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
            held.hold(wanted.view, top: inset + wanted.top, width: wanted.width)
        }
    }
}

/// The window `AboveSheets` draws in: one level over the app's, under the keyboard and the
/// system's alerts. It never becomes key, so the keyboard, and the key window the browser's sheet
/// is anchored on (`WebAuth.presentationAnchor`), stay the app's.
final class AboveSheetsWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var placed: (top: CGFloat, width: CGFloat) = (0, 0)

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        host.view.backgroundColor = .clear
        backgroundColor = .clear
        rootViewController = host
        // What the content measures follows the text size, and where it stands the screen's
        // shape, neither of which reaches the view that holds it.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitVerticalSizeClass.self,
                                 UITraitHorizontalSizeClass.self]) { (window: AboveSheetsWindow, _) in
            window.reframe()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeKey: Bool { false }

    /// Draws `view`, `top` points under the screen's top, `width` points wide at most.
    func hold(_ view: AnyView, top: CGFloat, width: CGFloat) {
        host.rootView = view
        placed = (top, width)
        reframe()
        isHidden = false
    }

    private func reframe() {
        frame = Self.frame(fitting: { self.host.sizeThatFits(in: $0) }, top: placed.top, width: placed.width,
                           in: windowScene?.coordinateSpace.bounds ?? .zero)
    }

    /// The content's own size, `width` wide at most and never wider or taller than the screen,
    /// centred, `top` points under the screen's top and kept on it. A window smaller than what it
    /// draws would cut the content off and take no touch on the part cut off; a larger one would
    /// take the touches of the page beside it.
    static func frame(fitting: (CGSize) -> CGSize, top: CGFloat, width: CGFloat, in bounds: CGRect) -> CGRect {
        let fitted = fitting(CGSize(width: min(width, bounds.width), height: bounds.height))
        let size = CGSize(width: min(fitted.width, bounds.width), height: min(fitted.height, bounds.height))
        return CGRect(x: (bounds.width - size.width) / 2, y: max(0, min(top, bounds.height - size.height)),
                      width: size.width, height: size.height).integral
    }
}
