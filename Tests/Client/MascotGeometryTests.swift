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
    /// every combination: scale 0.25 and 4, the offset's width -4000 and 4000 and its height 0
    /// and 200, and a stroll of 0 and 4000. What the document refuses is `LookDocumentTests`';
    /// what the placement does with a value past these ends is `testPastTheDocumentsEnds…`.
    static var extremes: [Look.Mascot] {
        var all: [Look.Mascot] = [Look.Mascot()]
        for scale in [0.25, 4] as [CGFloat] {
            for x in [-4000, 4000] as [CGFloat] {
                for y in [0, 200] as [CGFloat] {
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

    /// Where the pane is: at rest over turns (the pane whole), at rest over nothing (no pane,
    /// and him floating), and under the keyboard (the pane short, and whole).
    struct Pane: CustomStringConvertible {
        var keyboard = false
        var presence = 1.0
        static let all = [Pane(), Pane(presence: 0), Pane(keyboard: true)]
        var description: String { keyboard ? "under the keyboard" : "at rest, presence \(presence)" }
    }

    private func stage(_ mascot: Look.Mascot?, composer: Look.Composer = Look.Composer(),
                       pane: Pane = Pane(), midline: CGFloat? = nil,
                       face: @escaping (MascotFacing) -> Void = { _ in }) throws -> Stage {
        var look = Look()
        look.composer = composer
        look.composer.surface = .flat
        if let mascot { look.mascot = mascot }
        let view = VStack(spacing: 0) {
            Spacer()
            Composer(typing: .constant(pane.keyboard), mic: .init(), presence: pane.presence, keyboard: pane.keyboard,
                     mascot: mascot == nil ? nil : MascotState(model: "claude-opus-5", activity: .searching),
                     midline: midline, face: face)
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

    /// The well, as the composer lays it out: in the middle of the stage, since the pane is, at
    /// the size the keyboard leaves it.
    private func well(_ composer: Look.Composer = Look.Composer(), pane: Pane = Pane()) -> CGRect {
        let size = ComposerGeometry.of(composer, keyboard: pane.keyboard).well
        return CGRect(x: narrowest.width / 2 - size / 2, y: 0, width: size, height: narrowest.height)
            .intersection(CGRect(origin: .zero, size: narrowest))
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] { try LookStage.bytes(image) }

    /// Holds the jewel's column of the screen — the whole well and everything above and below it
    /// — to the same pixels with Topo as without him, and his canvas to the flank's side of it,
    /// and that a touch anywhere on the well reaches no part of him.
    func testTheJewelIsTheSameWithHimAtEveryExtreme() throws {
        for pane in Pane.all { try jewelIsTheSameWithHim(pane) }
    }

    /// The whole of the test above, for one pane: at rest over turns, at rest over nothing with
    /// him floating, and short under the keyboard with him placed from the short pane.
    private func jewelIsTheSameWithHim(_ pane: Pane) throws {
        let without = try stage(nil, pane: pane)
        defer { without.window.isHidden = true }
        XCTAssertNil(without.canvas)
        let bare = try pixels(without.image)
        let well = well(pane: pane)
        let scale = Int(without.image.scale)
        let width = Int(narrowest.width) * scale
        // The pane's foot and height, read off him at home: his canvas runs from the top of him,
        // standing on the pane's top edge at one point a pixel whatever the pane's height, with
        // room above for the bob, to the pane's foot.
        let home = try stage(Look.Mascot(), pane: pane)
        defer { home.window.isHidden = true }
        let homeCanvas = try XCTUnwrap(home.canvas)
        let paneFoot = homeCanvas.maxY
        let paneHeight = homeCanvas.height - CGFloat(Topo.shelfY) - Look.Mascot().bobAmplitude

        for mascot in Self.extremes {
            let with = try stage(mascot, pane: pane)
            defer { with.window.isHidden = true }
            let canvas = try XCTUnwrap(with.canvas, "\(pane), \(mascot): he was not drawn")
            XCTAssertLessThanOrEqual(canvas.maxX, well.minX + 0.5, "\(pane), \(mascot): his canvas reaches the well")

            // He stays in his slot's band: his canvas ends at the pane's foot and reaches no
            // higher than he stands tall over the pane's top edge, with his bob above him.
            XCTAssertEqual(canvas.maxY, paneFoot, accuracy: 0.5, "\(pane), \(mascot): his canvas left the pane's foot")
            XCTAssertLessThanOrEqual(canvas.height, paneHeight + CGFloat(Topo.shelfY) * mascot.scale
                                        + mascot.bobAmplitude + 0.5,
                                     "\(pane), \(mascot): his canvas grew past his band")

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
            XCTAssertEqual(differing, 0, "\(pane), \(mascot): the well's column changed with him on the glass")

            // And he is to be seen in it, not pushed out of his own canvas.
            var seen = 0
            let box = canvas.intersection(CGRect(origin: .zero, size: narrowest))
            for y in Int(box.minY) * scale..<Int(box.maxY) * scale {
                for x in Int(box.minX) * scale..<Int(box.maxX) * scale {
                    let i = (y * width + x) * 4
                    if (0..<4).contains(where: { abs(Int(drawn[i + $0]) - Int(bare[i + $0])) > 2 }) { seen += 1 }
                }
            }
            XCTAssertGreaterThan(seen, 0, "\(pane), \(mascot): nothing of him is drawn in his canvas")

            // A touch on the well reaches the hosting view, never him. SwiftUI puts no view of its
            // own under a gesture, so UIKit can say no more than that he is not what is hit: that
            // the press reaches the microphone is `TopoOnTheGlassTests`, which presses it.
            for point in [CGPoint(x: well.midX, y: narrowest.height - 50), CGPoint(x: well.minX + 2, y: narrowest.height - 50)] {
                let hit = with.window.hitTest(point, with: nil)
                XCTAssertFalse(hit is MascotCanvas, "\(pane), \(mascot): a touch on the well reached him")
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
        var moved = Look.Mascot(); moved.offset = CGSize(width: -10, height: 6)
        let offset = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: moved)
        XCTAssertEqual(offset.frame.minX + offset.home.x, base.frame.minX + base.home.x - 10)
        XCTAssertEqual(offset.frame.minY + offset.home.y, base.frame.minY + base.home.y + 6)
        var far = Look.Mascot(); far.stroll = 10
        XCTAssertEqual(MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: far).corner, -10)
        // The frame interval is the clock's, in `MascotDriverTests.testTheLinkRunsExactlyWhileHeAnimates`.
    }

    /// A value past the document's ends — a look built in code, or a range widened later — is
    /// still drawn inside his band: the placement clamps what it is handed rather than trusting
    /// the reader to have.
    func testPastTheDocumentsEndsHeStaysInHisBand() {
        let composer = Look.Composer()
        for height in [-4000, -1, 201, 4000] as [CGFloat] {
            var mascot = Look.Mascot()
            mascot.offset.height = height
            let placement = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: mascot)
            let shelf = placement.frame.minY + placement.home.y
            XCTAssertGreaterThanOrEqual(shelf, -composer.verticalInset, "\(height)")
            XCTAssertLessThanOrEqual(shelf, row.height + composer.verticalInset, "\(height)")
            XCTAssertGreaterThanOrEqual(placement.frame.minY,
                                        -composer.verticalInset - CGFloat(Topo.shelfY) - mascot.bobAmplitude - 1e-9, "\(height)")
        }
    }

    /// Whatever the look says, he stands between the pane's leading end and the well, and his
    /// stroll ends at the pane's end.
    func testTheFieldsAreClampedToTheFlank() {
        let composer = Look.Composer()
        for mascot in Self.extremes {
            let placement = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: mascot)
            XCTAssertEqual(placement.frame.maxX, flank.maxX + composer.spacing, "\(mascot)")
            XCTAssertGreaterThanOrEqual(placement.home.x, 0, "\(mascot)")
            XCTAssertLessThanOrEqual(placement.home.x, placement.frame.width, "\(mascot)")
            XCTAssertLessThanOrEqual(-placement.corner * Double(placement.scale), Double(placement.home.x) + 1e-9,
                                     "\(mascot): the stroll goes past the pane's end")
            XCTAssertLessThanOrEqual(placement.corner, 0)
            // He stands between the pane's top edge and its foot, and the canvas reaches no
            // higher than he stands tall over the top edge.
            let shelf = placement.frame.minY + placement.home.y
            XCTAssertGreaterThanOrEqual(shelf, -composer.verticalInset, "\(mascot): lifted off the pane")
            XCTAssertLessThanOrEqual(shelf, row.height + composer.verticalInset, "\(mascot): below the pane")
            XCTAssertGreaterThanOrEqual(placement.frame.minY,
                                        -composer.verticalInset - CGFloat(Topo.shelfY) * placement.scale
                                            - mascot.bobAmplitude - 1e-9,
                                        "\(mascot): the canvas grew past his band")
        }
        // A flank with no room at all is no placement.
        let none = MascotPlacement.of(flank: CGRect(x: 0, y: 0, width: 0, height: 0), row: row,
                                      composer: { var c = composer; c.spacing = 0; c.horizontalInset = 0; return c }(),
                                      mascot: Look.Mascot())
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Floating, settling, and the short pane

    /// At no presence, halfway and whole, on the resting pane and the short one, at every extreme
    /// of his fields: every picture of him through a whole bob is inside the frame he is clipped
    /// to, the frame ends at the well's leading edge — never over the jewel — and at the pane's
    /// leading end, and he stands between the pane's top edge and its foot as drawn.
    func testFloatingOrSettledOnEitherPaneHeStaysInHisFlank() {
        let composer = Look.Composer()
        for keyboard in [false, true] {
            let geometry = ComposerGeometry.of(composer, keyboard: keyboard)
            // The flank keeps its width: the well keeps its resting width in the row.
            let flank = CGRect(x: 0, y: geometry.well / 2, width: self.flank.width, height: 0)
            let row = CGSize(width: self.row.width, height: geometry.well)
            let wellEdge = flank.maxX + composer.spacing
            for mascot in Self.extremes + [{ var m = Look.Mascot(); m.bobAmplitude = 32; m.bobPeriod = 0.5; return m }()] {
                let placement = MascotPlacement.of(flank: flank, row: row, composer: composer, mascot: mascot,
                                                   share: geometry.scale)
                XCTAssertEqual(placement.scale, mascot.scale, accuracy: 1e-9,
                               "\(mascot): his scale is not the look's alone")
                XCTAssertEqual(placement.frame.maxX, wellEdge, accuracy: 1e-9, "\(mascot): his frame is not his flank")
                XCTAssertEqual(placement.frame.minX, -composer.horizontalInset, accuracy: 1e-9)
                let shelf = placement.frame.minY + placement.home.y
                XCTAssertGreaterThanOrEqual(shelf, -geometry.verticalInset - 1e-9, "\(mascot)")
                XCTAssertLessThanOrEqual(shelf, row.height + geometry.verticalInset + 1e-9, "\(mascot)")
                XCTAssertEqual(placement.frame.maxY, row.height + geometry.verticalInset, accuracy: 1e-9,
                               "\(mascot): his frame left the short pane's foot")
                for presence in [0, 0.5, 1] {
                    let hover = MascotHover(mascot, presence: presence)
                    for step in 0...16 {
                        let lift = hover.lift(at: mascot.bobPeriod * Double(step) / 16, reduceMotion: false)
                        XCTAssertGreaterThanOrEqual(lift, 0)
                        XCTAssertLessThanOrEqual(lift, mascot.bobAmplitude * CGFloat(1 - presence) + 1e-9,
                                                 "\(mascot), \(presence): the bob is not eased by the presence")
                        let sprite = placement.sprite(x: placement.corner, lift: lift)
                        XCTAssertGreaterThanOrEqual(sprite.minY, -1e-9,
                                                    "\(mascot), \(presence): his bob is clipped off the top of his frame")
                    }
                }
            }
        }
    }

    /// He keeps his size under the keyboard: at the resting pane's height, the short pane's and
    /// every share between them that the keyboard's rise animates through, at every extreme of
    /// his fields, his picture is the same size. His slot moves with the pane's edges; he does not
    /// shrink with them.
    func testHeKeepsHisSizeAtBothPaneHeights() {
        let composer = Look.Composer()
        let resting = ComposerGeometry.of(composer, keyboard: false)
        let short = ComposerGeometry.of(composer, keyboard: true)
        XCTAssertLessThan(short.scale, 1, "the pane does not go short under the keyboard")
        for mascot in Self.extremes + [Look.Mascot()] {
            func sprite(_ share: CGFloat, well: CGFloat) -> CGRect {
                let flank = CGRect(x: 0, y: well / 2, width: self.flank.width, height: 0)
                return MascotPlacement.of(flank: flank, row: CGSize(width: row.width, height: well), composer: composer,
                                          mascot: mascot, share: share).sprite(x: 0)
            }
            let tall = sprite(resting.scale, well: resting.well)
            XCTAssertEqual(tall.width, CGFloat(Topo.width) * mascot.scale, accuracy: 1e-9, "\(mascot)")
            XCTAssertEqual(tall.height, CGFloat(Topo.height) * mascot.scale, accuracy: 1e-9, "\(mascot)")
            for step in 0...4 {
                let share = short.scale + (1 - short.scale) * CGFloat(step) / 4
                let drawn = sprite(share, well: resting.well * share)
                XCTAssertEqual(drawn.size.width, tall.size.width, accuracy: 1e-9, "\(mascot), share \(share): he changed size")
                XCTAssertEqual(drawn.size.height, tall.size.height, accuracy: 1e-9, "\(mascot), share \(share): he changed size")
            }
        }
        // An animated share reaches him as the share, and still moves nothing of his size.
        var glass = MascotOnGlass(state: MascotState(model: "claude-opus-5"), flank: flank, row: row,
                                  share: 1, presence: 1, opacity: 1, covered: false)
        glass.animatableData = AnimatablePair(0.5, (1 + short.scale) / 2)
        XCTAssertEqual(glass.presence, 0.5)
        XCTAssertEqual(glass.share, (1 + short.scale) / 2, accuracy: 1e-9)
    }

    /// On iOS 17 there is no scroll geometry and the presence is 1, so he never floats there: the
    /// presence 1 is no lift at any moment of any bob the look can name.
    func testAPresenceOfOneIsNoLiftWhichIsIOS17() {
        for time in stride(from: 0.0, through: 20, by: 0.1) {
            XCTAssertEqual(MascotHover(amplitude: 32, period: 0.5, presence: 1).lift(at: time, reduceMotion: false), 0)
        }
    }

    /// The bob, as arithmetic: nothing at the start of a period, the whole amplitude halfway, a
    /// share of it at a share of the presence, and nothing at all under Reduce Motion or on the
    /// glass whole.
    func testTheBobEasesOutWithThePresenceAndIsNoneUnderReduceMotion() {
        let hover = { (presence: Double) in MascotHover(amplitude: 8, period: 2, presence: presence) }
        XCTAssertEqual(hover(0).lift(at: 0, reduceMotion: false), 0)
        XCTAssertEqual(hover(0).lift(at: 1, reduceMotion: false), 8, accuracy: 1e-9)
        XCTAssertEqual(hover(0.5).lift(at: 1, reduceMotion: false), 4, accuracy: 1e-9)
        XCTAssertEqual(hover(0.75).lift(at: 1, reduceMotion: false), 2, accuracy: 1e-9)
        XCTAssertEqual(hover(1).lift(at: 1, reduceMotion: false), 0)
        for presence in [0, 0.5, 1] {
            for time in stride(from: 0.0, through: 4, by: 0.25) {
                XCTAssertEqual(hover(presence).lift(at: time, reduceMotion: true), 0, "\(presence), \(time)")
            }
        }
        XCTAssertEqual(MascotHover(amplitude: 8, period: 0, presence: 0).lift(at: 1, reduceMotion: false), 0,
                       "a bob with no period is a division by nothing")
    }

    // MARK: Facing

    /// The facing is which half of the transcript his centre is in: right of the midline faces
    /// right, which the engine draws mirrored with the sign held out to the left; left of it, and
    /// on it, is the picture as drawn. A measure that is not a number decides the picture as drawn.
    func testTheFacingIsTheHalfOfTheTranscriptHisCentreIsIn() {
        XCTAssertEqual(MascotFacing.of(centreX: 161, midlineX: 160), .right, "the right half")
        XCTAssertEqual(MascotFacing.of(centreX: 160.01, midlineX: 160), .right, "just right of the line")
        XCTAssertEqual(MascotFacing.of(centreX: 159, midlineX: 160), .left, "the left half")
        XCTAssertEqual(MascotFacing.of(centreX: 160, midlineX: 160), .left, "on the line")
        XCTAssertEqual(MascotFacing.of(centreX: .nan, midlineX: 160), .left)
        XCTAssertEqual(MascotFacing.of(centreX: 200, midlineX: .infinity), .left)
        XCTAssertEqual(MascotFacing.of(centreX: .infinity, midlineX: 160), .left)
    }

    /// A placement faces from his body's axis at home, not from the middle of his frame or of the
    /// picture: the midline on his axis is the picture as drawn, a point to its left faces him
    /// right, and a point to its right faces him left — at home in the middle of his flank, and
    /// moved off it by the look's offset, where his axis is not his frame's middle.
    func testAPlacementFacesFromHisAxisAtHome() {
        var moved = Look.Mascot(); moved.offset.width = -12
        for mascot in [Look.Mascot(), moved] {
            let placement = MascotPlacement.of(flank: flank, row: row, composer: Look.Composer(), mascot: mascot)
            let axis = placement.frame.minX + placement.home.x
            if mascot == moved {
                XCTAssertNotEqual(axis, placement.frame.midX, "the test cannot tell his axis from his frame's middle")
            }
            XCTAssertEqual(placement.facing(midline: axis), .left, "\(mascot): on the line")
            XCTAssertEqual(placement.facing(midline: axis - 0.5), .right, "\(mascot): he is right of the line")
            XCTAssertEqual(placement.facing(midline: axis + 0.5), .left, "\(mascot): he is left of the line")
        }
    }

    /// On the glass, the composer hands up the facing his placement decides against the midline it
    /// is given in the global space. On main he stands on the leading flank, left of the middle of
    /// the screen, so the screen's own midline faces him as drawn; a midline left of him — the
    /// line the roost of a later layout is decided against — faces him right. No midline decides
    /// nothing.
    func testTheComposerHandsUpTheFacingOfWhereHeStands() throws {
        var told: [MascotFacing] = []
        let middle = try stage(Look.Mascot(), midline: narrowest.width / 2) { told.append($0) }
        defer { middle.window.isHidden = true }
        let canvas = try XCTUnwrap(middle.canvas)
        XCTAssertLessThan(canvas.maxX, narrowest.width / 2, "he is not on the left half")
        XCTAssertEqual(told.last, .left)

        told = []
        let left = try stage(Look.Mascot(), midline: canvas.minX) { told.append($0) }
        defer { left.window.isHidden = true }
        XCTAssertEqual(told.last, .right)

        told = []
        let none = try stage(Look.Mascot()) { told.append($0) }
        defer { none.window.isHidden = true }
        XCTAssertTrue(told.isEmpty, "no midline decided \(told)")
    }
}
