import SwiftUI
import UIKit

/// Draws `content` in a window of its own over the scene's windows, so it stands over a sheet the
/// system presents on the app's window (`WebAuth`'s browser), which no view in the app's own
/// window can be drawn over. The window is exactly the size of what it holds, at `top` points
/// under the scene's safe area and centred, `width` points wide at most: a touch anywhere else
/// reaches the sheet under it, so nothing of the sheet is taken from the person but what the
/// content covers. Nil content, or this view leaving the screen, takes the window away.
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
    /// scene is the one it was last in a window of: a sheet presented over the screen can take
    /// the screen's views out of the window, which is the moment the window above is wanted.
    final class Anchor: UIView {
        private(set) var above: AboveSheetsWindow?
        private weak var scene: UIWindowScene?
        private var wanted: (view: AnyView, top: CGFloat, width: CGFloat)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let found = window?.windowScene { scene = found }
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
            held.hold(wanted.view, top: wanted.top, width: wanted.width)
        }
    }
}

/// The window `AboveSheets` draws in: one level over the app's, under the keyboard and the
/// system's alerts.
final class AboveSheetsWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        host.view.backgroundColor = .clear
        backgroundColor = .clear
        rootViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func hold(_ view: AnyView, top: CGFloat, width: CGFloat) {
        host.rootView = view
        frame = Self.frame(for: host, top: top, width: width, in: windowScene)
        isHidden = false
    }

    /// The content's own size, `width` wide at most and never wider than the scene, centred,
    /// `top` points under the scene's safe area. A window smaller than what it draws would cut
    /// the content off and take no touch on the part cut off.
    static func frame(for host: UIHostingController<AnyView>, top: CGFloat, width: CGFloat, in scene: UIWindowScene?) -> CGRect {
        let bounds = scene?.coordinateSpace.bounds ?? .zero
        let inset = scene?.windows.first(where: { !($0 is AboveSheetsWindow) })?.safeAreaInsets.top ?? 0
        let wide = min(width, bounds.width)
        let fitted = host.sizeThatFits(in: CGSize(width: wide, height: bounds.height))
        let size = CGSize(width: min(fitted.width, bounds.width), height: min(fitted.height, bounds.height))
        return CGRect(x: (bounds.width - size.width) / 2, y: min(inset + top, bounds.height - size.height),
                      width: size.width, height: size.height).integral
    }
}
