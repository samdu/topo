import SwiftUI
import TopoMascot
import UIKit
import XCTest

@testable import Topo

/// Topo never breaks the microphone. He is laid over the composer's row rather than in it, clipped
/// to his flank and taking no touch, so the jewel is where it would be without him, drawn as it
/// would be without him, and pressed as it would be without him — at every extreme the look
/// document accepts for his size, offset and stroll, all at once, on the narrowest screen the app
/// runs on.
@MainActor
final class MascotGeometryTests: XCTestCase {
    /// The narrowest layout the iOS target supports: an iPad's Slide Over column, 320 points.
    private let narrowest = CGSize(width: 320, height: 420)

    /// The ends of every range `look.json` accepts for his fields (`LookDocument`'s readers), in
    /// every combination.
    private var extremes: [Look.Mascot] {
        var all: [Look.Mascot] = [Look.Mascot()]
        for scale in [0.25, 4] as [CGFloat] {
            for x in [-4000, 4000] as [CGFloat] {
                for y in [-4000, 4000] as [CGFloat] {
                    for stroll in [0, 4000] as [CGFloat] {
                        var mascot = Look.Mascot()
                        mascot.scale = scale
                        mascot.offset = CGSize(width: x, height: y)
                        mascot.stroll = stroll
                        all.append(mascot)
                    }
                }
            }
        }
        return all
    }

    // MARK: On the stage

    /// One composer on a window of the narrowest width, with Topo or without him.
    private struct Stage {
        let window: UIWindow
        let image: UIImage
        /// Topo's canvas, in the window's space, when he is drawn.
        let canvas: CGRect?
        let canvasView: MascotCanvas?
    }

    private func stage(_ mascot: Look.Mascot?, composer: Look.Composer = Look.Composer()) throws -> Stage {
        var look = Look()
        look.composer = composer
        look.composer.surface = .flat
        if let mascot { look.mascot = mascot }
        let view = VStack(spacing: 0) {
            Spacer()
            Composer(typing: .constant(false), mic: .init(),
                     mascot: mascot == nil ? nil : MascotState(model: "claude-opus-5", activity: .searching))
        }
        .environment(\.look, look)
        // A view hosted outside the app's scene reads as backgrounded, and he draws nothing there.
        .environment(\.scenePhase, .active)
        .transaction { $0.animation = nil }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: narrowest)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        window.layer.speed = 0
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: narrowest).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let canvas = find(MascotCanvas.self, in: window)
        return Stage(window: window, image: image, canvas: canvas.map { $0.convert($0.bounds, to: window) },
                     canvasView: canvas)
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let view = view as? T { return view }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// The well, as the composer lays it out: in the middle of the stage, since the pane is.
    private func well(_ composer: Look.Composer = Look.Composer()) -> CGRect {
        let size = composer.well.size
        return CGRect(x: narrowest.width / 2 - size / 2, y: 0, width: size, height: narrowest.height)
            .intersection(CGRect(origin: .zero, size: narrowest))
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] { try LookStage.bytes(image) }

    /// Holds the jewel's column of the screen — the whole well and everything above and below it
    /// — to the same pixels with Topo as without him, and his canvas to the flank's side of it,
    /// and that a touch anywhere on the well reaches no part of him.
    func testTheJewelIsTheSameWithHimAtEveryExtreme() throws {
        let without = try stage(nil)
        defer { without.window.isHidden = true }
        XCTAssertNil(without.canvas)
        let bare = try pixels(without.image)
        let well = well()
        let scale = Int(without.image.scale)
        let width = Int(narrowest.width) * scale

        for mascot in extremes {
            let with = try stage(mascot)
            defer { with.window.isHidden = true }
            let canvas = try XCTUnwrap(with.canvas, "\(mascot): he was not drawn")
            XCTAssertLessThanOrEqual(canvas.maxX, well.minX + 0.5, "\(mascot): his canvas reaches the well")

            // Every pixel of the well's column is the same, with a shade for the render server's
            // rounding on a curve's edge.
            let drawn = try pixels(with.image)
            var differing = 0
            for y in 0..<(Int(narrowest.height) * scale) {
                for x in Int(well.minX) * scale..<Int(well.maxX) * scale {
                    let i = (y * width + x) * 4
                    for c in 0..<4 where abs(Int(drawn[i + c]) - Int(bare[i + c])) > 2 { differing += 1 }
                }
            }
            XCTAssertEqual(differing, 0, "\(mascot): the well's column changed with him on the glass")

            // A touch on the well reaches the hosting view, never him.
            for point in [CGPoint(x: well.midX, y: narrowest.height - 50), CGPoint(x: well.minX + 2, y: narrowest.height - 50)] {
                let hit = with.window.hitTest(point, with: nil)
                XCTAssertFalse(hit is MascotCanvas, "\(mascot): a touch on the well reached him")
                if let canvasView = with.canvasView { XCTAssertFalse(hit?.isDescendant(of: canvasView) ?? false) }
            }
        }
    }

    /// With him drawn somewhere, the stage is different somewhere: the test above is not holding
    /// two pictures of nothing.
    func testHeIsDrawnAtAll() throws {
        let without = try stage(nil)
        defer { without.window.isHidden = true }
        let with = try stage(Look.Mascot())
        defer { with.window.isHidden = true }
        XCTAssertTrue(try LookStage.differ(try pixels(without.image), try pixels(with.image)),
                      "Topo drew nothing on the stage")
    }

    /// A pane too narrow for anything but the microphone has no flank to draw him in, and he is
    /// not drawn at all rather than drawn over it.
    func testNoFlankIsNoTopo() throws {
        var narrow = Look.Composer()
        narrow.widthFraction = 0.1
        let with = try stage(Look.Mascot(), composer: narrow)
        defer { with.window.isHidden = true }
        XCTAssertNil(with.canvas, "a pane with no flank drew him anyway")
        // And the arithmetic: a flank with no width is no placement, whatever the inset and the
        // spacing around it would give.
        XCTAssertTrue(MascotPlacement.of(flank: CGRect(x: 10, y: 36, width: 0, height: 0), row: row,
                                         composer: Look.Composer(), mascot: Look.Mascot()).isEmpty)
    }

    // MARK: The placement, as arithmetic

    private let flank = CGRect(x: 0, y: 36, width: 60, height: 0)
    private let row = CGSize(width: 202, height: 72)

    /// Home is the middle of the room from the pane's leading end to the well, on the pane's top
    /// edge, and the frame he is clipped to is exactly that room.
    func testHomeIsTheMiddleOfTheFlankOnThePanesTopEdge() {
        let composer = Look.Composer()
        let placement = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: Look.Mascot())
        XCTAssertEqual(placement.frame.minX, -composer.horizontalInset)
        XCTAssertEqual(placement.frame.maxX, flank.maxX + composer.spacing)
        XCTAssertEqual(placement.frame.maxY, row.height + composer.verticalInset, "the pane's foot")
        XCTAssertEqual(placement.frame.minX + placement.home.x, (placement.frame.minX + placement.frame.maxX) / 2)
        XCTAssertEqual(placement.frame.minY + placement.home.y, -composer.verticalInset, "the pane's top edge")
        let sprite = placement.sprite(x: 0)
        XCTAssertEqual(sprite.minX + CGFloat(Topo.bodyX), placement.home.x, "his body stands at home")
        XCTAssertEqual(sprite.minY + CGFloat(Topo.shelfY), placement.home.y, "his shelf row is the pane's edge")
        XCTAssertEqual(placement.corner, -36, "the look's stroll, in art pixels at one point each")
    }

    /// Each of his four fields reaches where he is drawn or how often: a field nothing draws with
    /// is a value the mind cannot reach.
    func testEveryFieldIsDrawnWith() {
        let composer = Look.Composer()
        let base = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: Look.Mascot())
        var big = Look.Mascot(); big.scale = 2
        let scaled = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: big)
        XCTAssertEqual(scaled.sprite(x: 0).width, base.sprite(x: 0).width * 2)
        XCTAssertEqual(scaled.corner, base.corner / 2, "the stroll is points, so fewer art pixels at twice the size")
        var moved = Look.Mascot(); moved.offset = CGSize(width: -10, height: -6)
        let offset = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: moved)
        XCTAssertEqual(offset.frame.minX + offset.home.x, base.frame.minX + base.home.x - 10)
        XCTAssertEqual(offset.frame.minY + offset.home.y, base.frame.minY + base.home.y - 6)
        var far = Look.Mascot(); far.stroll = 10
        XCTAssertEqual(MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: far).corner, -10)
        // The frame interval is the clock's, in `MascotDriverTests.testTheLinkRunsExactlyWhileHeAnimates`.
    }

    /// Whatever the look says, he stands between the pane's leading end and the well, and his
    /// stroll ends at the pane's end.
    func testTheFieldsAreClampedToTheFlank() {
        let composer = Look.Composer()
        for mascot in extremes {
            let placement = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: mascot)
            XCTAssertEqual(placement.frame.maxX, flank.maxX + composer.spacing, "\(mascot)")
            XCTAssertGreaterThanOrEqual(placement.home.x, 0, "\(mascot)")
            XCTAssertLessThanOrEqual(placement.home.x, placement.frame.width, "\(mascot)")
            XCTAssertLessThanOrEqual(-placement.corner * Double(placement.scale), Double(placement.home.x) + 1e-9,
                                     "\(mascot): the stroll goes past the pane's end")
            XCTAssertLessThanOrEqual(placement.corner, 0)
        }
        // A flank with no room at all is no placement.
        let none = MascotPlacement.of(flank: CGRect(x: 0, y: 0, width: 0, height: 0), row: row,
                                      composer: { var c = composer; c.spacing = 0; c.horizontalInset = 0; return c }(),
                                      mascot: Look.Mascot())
        XCTAssertTrue(none.isEmpty)
    }
}
