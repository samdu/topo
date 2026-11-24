import SwiftUI
import UIKit

/// Draws `content` in a window of its own over the scene's windows, so it stands over a sheet the
/// system presents on the app's window (`WebAuth`'s browser), which no view in the app's own
/// window can be drawn over. The window is the size of what it holds at its ideal height, at
/// `top` points under the app window's safe area and centred, `width` points wide at most: a touch
/// anywhere else reaches the sheet under it, so nothing of the sheet is taken from the person but
/// what the content covers. Nil content, or this view being torn down, takes the window away; the
/// view merely leaving its window under a presentation does not.
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
        anchor.show(content.map { AnyView($0) }, top: top, width: width)
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
        /// The app's window it was last in, whose safe area is read each time the window above
        /// is placed, so a rotation under the sheet places it from the safe area of then.
        private weak var source: UIWindow?
        private var wanted: (view: AnyView, top: CGFloat, width: CGFloat)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, window.windowScene != nil { source = window }
            place()
        }

        func show(_ view: AnyView?, top: CGFloat, width: CGFloat) {
            wanted = view.map { ($0, top, width) }
            place()
        }

        private func place() {
            guard let wanted, let source, let scene = source.windowScene else {
                above?.isHidden = true
                above = nil
                return
            }
            let held = above ?? AboveSheetsWindow(windowScene: scene)
            above = held
            held.hold(wanted.view, top: { [weak source] in (source?.safeAreaInsets.top ?? 0) + wanted.top },
                      width: wanted.width)
        }
    }
}

/// The window `AboveSheets` draws in: one level over the app's, under the keyboard and the
/// system's alerts. It never becomes key, so the keyboard, and the key window the browser's sheet
/// is anchored on (`WebAuth.presentationAnchor`), stay the app's.
final class AboveSheetsWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    /// Where it stands, read again at each placing: points under the screen's top.
    private var top: () -> CGFloat = { 0 }
    private var width: CGFloat = 0
    private var geometry: NSKeyValueObservation?

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        host.view.backgroundColor = .clear
        // The window stands clear of the screen's edges where it is placed; the insets it would
        // inherit while it is still the scene's size are space measured into the content.
        host.safeAreaRegions = []
        backgroundColor = .clear
        rootViewController = host
        // What the content measures follows the text size, and where it stands the scene's
        // geometry and the app window's safe area, none of which reaches the view that holds it.
        // The geometry is observed as UIKit recommends, by KVO of `effectiveGeometry`, which a
        // rotation and an iPad's resize both change; the app window's safe area follows the
        // geometry in the layout after it, so it is placed again once that has run.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (window: AboveSheetsWindow, _) in
            window.reframe()
        }
        geometry = windowScene.observe(\.effectiveGeometry) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.reframe()
                DispatchQueue.main.async { [weak self] in self?.reframe() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeKey: Bool { false }

    /// Draws `view`, `top` points under the screen's top, `width` points wide at most.
    func hold(_ view: AnyView, top: @escaping () -> CGFloat, width: CGFloat) {
        host.rootView = view
        self.top = top
        self.width = width
        reframe()
        isHidden = false
    }

    private func reframe() {
        // The height the content takes at that width when nothing bounds it, which is its own:
        // a height proposed to it, the screen's, is a height a flexible frame in it fills.
        frame = Self.frame(fitting: { size in
            self.host.view.systemLayoutSizeFitting(CGSize(width: size.width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel)
        }, top: top(), width: width, in: windowScene?.coordinateSpace.bounds ?? .zero)
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
