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
/// them, which is what makes "this field reaches the pixels" a question about the whole look and
/// not about the part of it one renderer happens to draw.
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
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        window.layoutIfNeeded()

        // A `ProgressView`'s spinner is a Core Animation on its own layer, which neither
        // `setAnimationsEnabled(false)` nor a cleared transaction stops: they govern animations
        // started from here, and that one is started by the control. Stopping the layer tree's
        // clock at a fixed offset is what makes it the same picture every time — every layer
        // under this window is then drawn at the same moment of whatever it is doing.
        window.layer.speed = 0
        window.layer.timeOffset = 0
        // SwiftUI commits its layout on the run loop, and `afterScreenUpdates` draws what the
        // render server has: both want a turn of the loop before the picture is taken.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The same, as a digest: what a failure here has to say is that two pictures are the same,
    /// and the bytes are not worth printing. A blank picture is a failure of its own — a stage
    /// that drew nothing would make every look look alike.
    static func raster(_ view: some View, look: Look, style: UIUserInterfaceStyle = .light,
                       size: CGSize = LookStage.size) throws -> String {
        try digest(try image(view, look: look, style: style, size: size))
    }

    static func digest(_ image: UIImage) throws -> String {
        let bytes = try pixels(of: image)
        XCTAssertGreaterThan(Set(bytes).count, 8, "the stage drew a blank picture, so it says nothing")
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The settled bitmap of a view: what two staged pictures are compared by, since a digest is
    /// the wrong currency for the render server — see `differ`.
    static func plane(_ view: some View, look: Look, style: UIUserInterfaceStyle = .light,
                      size: CGSize = LookStage.size) throws -> [UInt8] {
        try pixels(of: try image(view, look: look, style: style, size: size))
    }

    /// Whether two pictures are pictures of two different things.
    ///
    /// A digest is the right question of `ImageRenderer`, which draws the same bytes from the
    /// same view every time. It is not the right question of the render server: the same view
    /// drawn through two windows rounds the antialiasing on a curve's edge a shade either way,
    /// so a handful of pixels differ by one in a channel between two drawings of one picture.
    /// What is asked here is therefore that something differ by more than a shade — which every
    /// field of the look that draws at all does, since the fixture sets each to a value nothing
    /// like the compiled one.
    static func differ(_ a: [UInt8], _ b: [UInt8], by shade: UInt8 = 2) throws -> Bool {
        guard a.count == b.count else { return true }
        for (one, other) in zip(a, b) where one > other ? one - other > shade : other - one > shade {
            return true
        }
        return false
    }

    /// The bitmap behind a render, which is what two pictures are the same or different by.
    static func pixels(of image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return bytes
    }
}
