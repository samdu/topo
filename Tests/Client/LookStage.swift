import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// A view drawn the way the phone draws it: through a real window and the render server, rather
/// than by `ImageRenderer`.
///
/// `ImageRenderer` is the cheaper path and the right one for a row or a lozenge, but it is a
/// partial renderer: it lays out nothing inside a `ScrollView`, gives a `containerRelativeFrame`
/// no container, draws no `TextField`'s text, composites none of the system's own glass, and
/// applies no `.saturation`. Every one of those is a field of `Look` a still could not otherwise
/// be asked about. A `UIHostingController` in a `UIWindow` drawn with
/// `drawHierarchy(in:afterScreenUpdates:)` goes through the render server and applies all of
/// them.
@MainActor
enum LookStage {
    /// The phone-sized stage every render here is taken on.
    static let size = CGSize(width: 393, height: 780)

    /// One drawing of a view under a look, as bytes. The window is made on the host app's own
    /// scene so the view is laid out the way the app lays it out, and taken down again at the
    /// end of the call.
    ///
    /// Nothing animates while the picture is taken — neither UIKit's animations nor SwiftUI's
    /// implicit ones. A still is compared for equality, so a frame of something on its way
    /// somewhere is a picture of when it was taken rather than of the look, and the chat has an
    /// animation that runs on first appearance: the pane's presence, which eases over
    /// `composer.presenceDuration` off scroll geometry that arrives after layout.
    static func image(_ view: some View, look: Look, style: UIUserInterfaceStyle = .light,
                      size: CGSize = LookStage.size) throws -> UIImage {
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animations) }

        let host = UIHostingController(
            rootView: view.environment(\.look, look).transaction { $0.animation = nil })
        // The window covers the whole screen as well as the stage, with the view on the stage
        // at its top left and the view's own background colour around it: the system's glass
        // samples a margin beyond its own edge, which from a pane near the stage's foot reaches
        // past the stage, and what is there is then this window's background rather than
        // whatever the host app's own window happens to be showing under it.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen.bounds.size ?? size
        let frame = CGRect(x: 0, y: 0, width: max(size.width, screen.width),
                           height: max(size.height, screen.height))
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let stage = UIViewController()
        stage.view.backgroundColor = .systemBackground
        stage.addChild(host)
        stage.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.didMove(toParent: stage)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = stage
        window.isHidden = false
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()

        // A `ProgressView`'s spinner is a Core Animation on its own layer, which neither
        // `setAnimationsEnabled(false)` nor a cleared transaction stops: they govern animations
        // started from here, and that one is started by the control. Stopping the layer tree's
        // clock at a fixed offset is what makes it the same picture every time — every layer
        // under this window is then drawn at the same moment of whatever it is doing.
        window.layer.speed = 0
        window.layer.timeOffset = 0
        try refreshed(window)
        // The whole window is drawn at its own size into a picture the stage's size, which
        // keeps the stage and clips the rest.
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// How many display refreshes the stage waits for after the window's commit before the
    /// picture is taken. Two is chosen and measured, not derived: a refresh is the display's
    /// tick, not an acknowledgement that this window was composited, and no public API gives
    /// one. On a simulator with every core saturated, capturing with no wait gave the unsettled
    /// glass 16 times in 40 and after 10 ms on the clock 5 in 40, where one, two or three
    /// refreshes gave it none in 40 each. That is the evidence two refreshes settle the glass in
    /// practice; it is no guarantee against a render server further behind than that.
    private static let refreshes = 2

    /// How long those refreshes may take before the stage gives up, which is a failure and never
    /// a picture: a stage that took the picture anyway would be the defect this wait exists for.
    private static let refreshesTimeout: TimeInterval = 10

    /// Waits for display refreshes after the window's commit, so the system's glass has had the
    /// chance of an on-screen backdrop before the picture is taken.
    ///
    /// The composer's glass is a `CABackdropLayer`, and `drawHierarchy` draws it from what the
    /// render server captured behind it the last time it composited the screen. A window that
    /// has never been on the screen has no such capture, and its glass is drawn from something
    /// else: an edge of the pane that lenses nothing where it should lens the window's own
    /// content, and a rim and a shadow missing along its foot. A window placed off the screen
    /// gives that picture every time, however long it waits; one the display has drawn gives the
    /// settled picture. So what the picture waits on is refreshes of the display rather than
    /// time on the clock, which is a guess at how soon the render server composites that a
    /// loaded CI runner loses. See `refreshes` for what two refreshes are and are not.

    ///
    /// The wait turns the run loop, which is also what SwiftUI commits its layout on.
    private static func refreshed(_ window: UIWindow) throws {
        CATransaction.flush()
        let counter = DisplayRefreshes()
        defer { counter.stop() }
        let deadline = Date().addingTimeInterval(refreshesTimeout)
        while counter.count < refreshes {
            guard Date() < deadline else {
                throw StageError.notRefreshed(refreshes: counter.count, of: refreshes,
                                              in: refreshesTimeout)
            }
            RunLoop.current.run(mode: .default,
                                before: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    /// The display's own refreshes, counted by a display link, from when it is made until it is
    /// stopped.
    private final class DisplayRefreshes: NSObject {
        private(set) var count = 0
        private var link: CADisplayLink?

        override init() {
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) { count += 1 }

        /// The link holds its target, so it is invalidated here rather than left to a deinit
        /// that would never come.
        func stop() {
            link?.invalidate()
            link = nil
        }
    }

    enum StageError: Error, CustomStringConvertible {
        case notRefreshed(refreshes: Int, of: Int, in: TimeInterval)

        var description: String {
            switch self {
            case .notRefreshed(let counted, let wanted, let seconds):
                return "the display refreshed \(counted) of \(wanted) times in \(seconds)"
                    + " seconds after the window went up, so no picture was taken"
            }
        }
    }

    /// One picture's pixels as a digest, for a comparison that is exact.
    static func digest(_ image: UIImage) throws -> String {
        SHA256.hash(data: Data(try bytes(image))).map { String(format: "%02x", $0) }.joined()
    }

    /// One picture's pixels, four bytes to each. A picture with nothing in it is a failure of
    /// its own: a stage that drew nothing would make every look look alike.
    static func bytes(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        XCTAssertGreaterThan(distinct(bytes, upTo: 9), 8, "the stage drew a blank picture, so it says nothing")
        return bytes
    }

    /// How many different values `bytes` holds, counted no further than `limit`. The pixel loops
    /// here are `while` loops over pointers because this bundle is built `-Onone`, where a `Set`
    /// of a whole screen's bytes, or a `for` over them, costs seconds a picture.
    static func distinct(_ bytes: [UInt8], upTo limit: Int) -> Int {
        var seen = [Bool](repeating: false, count: 256), count = 0
        bytes.withUnsafeBufferPointer { values in
            seen.withUnsafeMutableBufferPointer { seen in
                var i = 0
                while i < values.count, count < limit {
                    let value = Int(values[i])
                    if !seen[value] { seen[value] = true; count += 1 }
                    i += 1
                }
            }
        }
        return count
    }

    /// Whether two pictures are pictures of two different things.
    ///
    /// A digest is the right question of `ImageRenderer`, which draws the same bytes from the
    /// same view every time. It is not the right question of the render server: the same view
    /// drawn through two windows rounds the antialiasing on a curve's edge a shade either way,
    /// so a handful of pixels differ by one in a channel between two drawings of one picture.
    /// What is asked here is therefore that something differ by more than a shade.
    static func differ(_ a: [UInt8], _ b: [UInt8], by shade: UInt8 = 2) throws -> Bool {
        guard a.count == b.count else { return true }
        return a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                var i = 0
                while i < a.count {
                    let one = a[i], other = b[i]
                    if one > other ? one - other > shade : other - one > shade { return true }
                    i += 1
                }
                return false
            }
        }
    }
}
