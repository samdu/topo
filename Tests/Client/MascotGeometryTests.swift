import SwiftUI
import TopoCore
import TopoMascot
import UIKit
import XCTest

@testable import Topo

/// Topo never covers a word or the microphone. Where he stands is `MascotRoost.of`, a pure
/// function of the chat's geometry, held here over fixtures — an empty chat, long turns on both
/// sides, one gap only, no gap, the keyboard up, and the choice that moves him least — and at the
/// ends of the look's ranges for his size and his clearance; and the chat as drawn, with him over
/// it, is held to the same: his picture where the canvas draws it overlaps no turn and none of
/// the composer's pane, and the pane is the same pixels with him as without.
///
/// That a press on the well reaches the microphone with him beside it is `TopoOnTheGlassTests`',
/// which presses it; neither stands in for the other.
@MainActor
final class MascotGeometryTests: XCTestCase {
    // MARK: Fixtures

    /// A phone's transcript, 402 points wide, over a pane 320 wide and 80 tall with its 72-point
    /// well in the middle.
    static let visible = CGRect(x: 0, y: 0, width: 402, height: 628)
    static let pane = CGRect(x: 41, y: 540, width: 320, height: 80)
    static let well = CGRect(x: 165, y: 544, width: 72, height: 72)

    static func field(_ obstacles: [CGRect], keyboard: Bool = false) -> MascotField {
        if keyboard {
            // The keyboard is up from 400: the pane rides on it, short.
            return MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 400), obstacles: obstacles,
                               pane: CGRect(x: 41, y: 344, width: 320, height: 53),
                               well: CGRect(x: 177, y: 345, width: 48, height: 48),
                               keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
        }
        return MascotField(visible: visible, obstacles: obstacles, pane: pane, well: well)
    }

    /// Rows down the transcript, alternating sides, each `height` tall (Topo's `topoHeight`, when
    /// it is given) with 12 between: the person's on the right from `personMinX`, Topo's on the
    /// left to `topoMaxX`.
    nonisolated static func rows(height: CGFloat, topoHeight: CGFloat? = nil, personMinX: CGFloat, topoMaxX: CGFloat,
                                 until bottom: CGFloat = 628) -> [CGRect] {
        var rows: [CGRect] = []
        var y: CGFloat = 12
        var mine = true
        while y < bottom {
            let tall = mine ? height : topoHeight ?? height
            rows.append(mine ? CGRect(x: personMinX, y: y, width: 386 - personMinX, height: tall)
                             : CGRect(x: 16, y: y, width: topoMaxX - 16, height: tall))
            y += tall + 12
            mine.toggle()
        }
        return rows
    }

    struct Fixture {
        var name: String
        var field: MascotField
        /// Where he should stand at the default look, starting from nowhere.
        var roost: String
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "an empty chat", field: field([]), roost: "gap"),
        // Long turns on both sides, reaching under the pane as a scrolled transcript does: the
        // person's across the column, Topo's to the column's edge less his margin (150 points), so
        // the margin beside a reply is room.
        Fixture(name: "long turns on both sides",
                field: field(rows(height: 80, topoHeight: 160, personMinX: 60, topoMaxX: 236, until: 700)),
                roost: "gap"),
        // Every row full width but one short person's turn on the right with room to its left.
        Fixture(name: "one gap only",
                field: field([CGRect(x: 16, y: 0, width: 370, height: 200),
                              CGRect(x: 250, y: 212, width: 136, height: 120),
                              CGRect(x: 16, y: 344, width: 370, height: 284)]),
                roost: "gap"),
        Fixture(name: "no gap", field: field([CGRect(x: 0, y: 0, width: 402, height: 628)]), roost: "none"),
        Fixture(name: "the keyboard up, turns above it", field: field(rows(height: 40, personMinX: 330, topoMaxX: 150, until: 400),
                                                                      keyboard: true), roost: "gap"),
        Fixture(name: "the keyboard up, no gap", field: field([CGRect(x: 0, y: 0, width: 402, height: 400)], keyboard: true),
                roost: "none"),
    ]

    static let size = MascotSprite.size(scale: Look.Mascot().scale)

    // MARK: The roost

    func testEachFixtureHasTheRoostItShouldHave() {
        for fixture in Self.fixtures {
            let roost = MascotRoost.of(fixture.field, size: Self.size, clearance: 8, from: nil)
            XCTAssertEqual(roost.name, fixture.roost, fixture.name)
        }
    }

    /// With one gap only he stands in it, whatever he stood nearest before.
    func testTheOneGapIsWhereHeStands() throws {
        let field = Self.fixtures[2].field
        for from in [nil, CGPoint.zero, CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 0)] as [CGPoint?] {
            let frame = try XCTUnwrap(MascotRoost.of(field, size: Self.size, clearance: 8, from: from).frame)
            XCTAssertTrue(CGRect(x: 0, y: 200, width: 250, height: 144).contains(frame), "\(String(describing: from)): \(frame)")
        }
    }

    /// Of two gaps, the one nearer where he stands wins, so a new turn moves him the least; and the
    /// nearest place in a gap is the one closest to him, not its middle.
    func testTheGapNearestWhereHeStandsWins() throws {
        let field = Self.field([CGRect(x: 0, y: 150, width: 402, height: 250)])
        let size = Self.size
        let top = try XCTUnwrap(MascotRoost.of(field, size: size, clearance: 8, from: CGPoint(x: 200, y: 100)).frame)
        XCTAssertLessThanOrEqual(top.maxY, 150 - 8 + 0.001)
        XCTAssertEqual(top.minX, 200, accuracy: 0.001, "he moved sideways for nothing")
        let bottom = try XCTUnwrap(MascotRoost.of(field, size: size, clearance: 8, from: CGPoint(x: 20, y: 300)).frame)
        XCTAssertEqual(bottom.origin, CGPoint(x: 20, y: 408), "the nearest place clear of the turn is straight down")
        // Where he stands is already clear: he stays exactly there.
        let stay = try XCTUnwrap(MascotRoost.of(field, size: size, clearance: 8, from: CGPoint(x: 100, y: 20)).frame)
        XCTAssertEqual(stay.origin, CGPoint(x: 100, y: 20))
    }

    /// Of two places as near where he stands, the one on the right wins: a turn down the middle
    /// with room either side of it, and him over it.
    func testATieGoesToTheRight() throws {
        let field = Self.field([CGRect(x: 170, y: 0, width: 62, height: 628)])
        let from = CGPoint(x: 201 - Self.size.width / 2, y: 100)
        let frame = try XCTUnwrap(MascotRoost.of(field, size: Self.size, clearance: 8, from: from).frame)
        XCTAssertEqual(frame.minX, 232 + 8, accuracy: 0.001, "he went left: \(frame)")
        XCTAssertEqual(frame.minY, 100, accuracy: 0.001)
    }

    /// With no `from` he starts nearest the transcript's bottom trailing corner: the right margin,
    /// just above the glass and clear of it.
    func testWithNowhereToStartFromHeStartsInTheBottomTrailingCorner() throws {
        let frame = try XCTUnwrap(MascotRoost.of(Self.fixtures[0].field, size: Self.size, clearance: 8, from: nil).frame)
        XCTAssertEqual(frame.maxY, Self.pane.minY - 8, accuracy: 0.001, "he does not stand just over the glass")
        XCTAssertEqual(frame.maxX, Self.visible.maxX, accuracy: 0.001, "he does not stand flush in the right margin")
        XCTAssertFalse(MascotRoost.overlap(frame, Self.pane))
    }

    /// With no gap he is not drawn, at the default size and larger, whatever the clearance: the
    /// glass is never where he waits.
    func testWithNoGapHeIsNotDrawn() {
        for fixture in Self.fixtures where fixture.roost == "none" {
            for scale in [Look.Mascot().scale, 4] as [CGFloat] {
                for clearance in [0, 8, 64] as [CGFloat] {
                    XCTAssertEqual(MascotRoost.of(fixture.field, size: MascotSprite.size(scale: scale),
                                                  clearance: clearance, from: nil), .none,
                                   "\(fixture.name), scale \(scale), clearance \(clearance)")
                }
            }
        }
    }

    /// Under the keyboard the glass rides on it, short, and it is off limits as it is at the foot
    /// of the screen: with room above it he stands above its top edge, and with none he is not
    /// drawn. A frame reaching one point into the glass is not a roost.
    func testUnderTheKeyboardTheShortGlassIsOffLimits() throws {
        let roomy = Self.fixtures[4].field
        let pane = try XCTUnwrap(roomy.pane)
        let frame = try XCTUnwrap(MascotRoost.of(roomy, size: Self.size, clearance: 8, from: nil).frame)
        XCTAssertLessThanOrEqual(frame.maxY, pane.minY - 8 + 0.001, "\(frame) is not above the short glass")
        XCTAssertTrue(MascotRoost.holds(roomy, frame: frame, clearance: 8))
        let into = CGRect(x: frame.minX, y: pane.minY - frame.height + 1, width: frame.width, height: frame.height)
        XCTAssertFalse(MascotRoost.holds(roomy, frame: into, clearance: 0), "a frame over the glass holds")
        XCTAssertTrue(roomy.covers(into), "the glass does not cover him")
        XCTAssertEqual(MascotRoost.of(Self.fixtures[5].field, size: Self.size, clearance: 8, from: nil), .none)
    }

    // MARK: The bounds, from geometry, at every end

    /// At every fixture, at the ends of the look's ranges for his size (0.25 and 4, and the
    /// default) and his clearance (0 and 64, and the default), from nowhere and from four corners:
    /// his whole picture — every point of it, top to bottom — overlaps no turn, no row and none of
    /// the composer's pane; standing in a gap it keeps the clearance from every turn and stays in
    /// the transcript above the glass.
    func testHisPictureExcludesEveryObstacleAndThePaneAtEveryEnd() {
        for fixture in Self.fixtures {
            for scale in [0.25, Look.Mascot().scale, 4] as [CGFloat] {
                for clearance in [0, 8, 64] as [CGFloat] {
                    for from in [nil, CGPoint.zero, CGPoint(x: 400, y: 0), CGPoint(x: 0, y: 700), CGPoint(x: 400, y: 700)] as [CGPoint?] {
                        let size = MascotSprite.size(scale: scale)
                        let roost = MascotRoost.of(fixture.field, size: size, clearance: clearance, from: from)
                        let label = "\(fixture.name), scale \(scale), clearance \(clearance), from \(String(describing: from))"
                        assertClear(roost, in: fixture.field, size: size, clearance: clearance, label)
                    }
                }
            }
        }
    }

    private func assertClear(_ roost: MascotRoost, in field: MascotField, size: CGSize, clearance: CGFloat,
                             _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = roost.frame else { return }
        XCTAssertEqual(frame.size, size, label, file: file, line: line)
        XCTAssertEqual(roost.name, "gap", label, file: file, line: line)
        XCTAssertFalse(MascotRoost.overlap(frame, field.pane ?? .null), "\(label): over the pane", file: file, line: line)
        XCTAssertFalse(MascotRoost.overlap(frame, field.well ?? .null), "\(label): over the well", file: file, line: line)
        for obstacle in field.obstacles where MascotRoost.overlap(obstacle, field.seen) {
            XCTAssertFalse(MascotRoost.overlap(frame, obstacle.intersection(field.seen)), "\(label): over \(obstacle)",
                           file: file, line: line)
        }
        let room = frame.insetBy(dx: -clearance, dy: -clearance)
        XCTAssertTrue(field.open.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(label): out of the transcript",
                      file: file, line: line)
        for obstacle in field.covering {
            XCTAssertFalse(MascotRoost.overlap(room, obstacle), "\(label): within the clearance of \(obstacle)",
                           file: file, line: line)
        }
    }

    /// A line under the transcript — the error line, the one saying what is waiting, the offer
    /// card — is outside the transcript's frame and above the glass, and it covers him as a turn
    /// does; a turn scrolled under the glass or the navigation bar is not over him.
    func testALineUnderTheTranscriptCoversHimAndTextUnderTheGlassDoesNot() {
        let field = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 500),
                                obstacles: [CGRect(x: 16, y: 510, width: 300, height: 20),
                                            CGRect(x: 16, y: 560, width: 370, height: 40),
                                            CGRect(x: 16, y: -60, width: 370, height: 50)],
                                pane: Self.pane, well: Self.well)
        XCTAssertTrue(field.covers(CGRect(x: 20, y: 480, width: 60, height: 40)), "the line under the transcript")
        XCTAssertFalse(field.covers(CGRect(x: 362, y: 560, width: 24, height: 40)), "a turn under the glass, beside the pane")
        XCTAssertTrue(field.covers(CGRect(x: 290, y: 560, width: 60, height: 40)), "the pane itself")
        XCTAssertFalse(field.covers(CGRect(x: 20, y: -50, width: 60, height: 40)), "a turn under the bar")
    }

    /// Nothing the roost is handed that is not a size puts him anywhere.
    func testNoSizeIsNoTopo() {
        for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.infinity, height: 10),
                     CGSize(width: CGFloat.nan, height: 10)] {
            XCTAssertEqual(MascotRoost.of(Self.fixtures[0].field, size: size, clearance: 8, from: nil), .none, "\(size)")
        }
    }

    // MARK: His picture

    /// He rests inside `MascotSprite.box`: sitting on the shelf at home, breathing, blinking,
    /// looking about and his arms drifting, on every head and every load band, nothing is drawn
    /// outside it. Each run is two minutes of the idle cycle, which is more than one turn of the
    /// slowest arm's drift, drawn only while he has sat at home for a second — an excursion's
    /// walk home, the corner and yoga are not rest.
    func testHeRestsInsideTheBox() {
        let box = MascotSprite.box
        var reached = Reach()
        for (m, model) in ["claude-haiku-4-5", "claude-opus-5", "claude-fable-5-1"].enumerated() {
            // One token count in each band: default, warning, reset, untrusted.
            for (b, tokens) in [1_000.0, 210_000, 260_000, 320_000].enumerated() {
                var random = Mulberry32(seed: UInt32(m * 4 + b + 1))
                let engine = Topo(random: { random.next() })
                var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
                var home = 0.0
                for frame in 0..<(120 * 30) {
                    engine.update(1.0 / 30, TopoInput(model: model, tokens: tokens, activity: "idle", corner: 0))
                    let resting = engine.poseName == "shelf" && engine.x == 0 && engine.outing == nil
                    home = resting ? home + 1.0 / 30 : 0
                    // The head and the load settle from the engine's start in under two seconds.
                    guard frame >= 60, home > 1, frame % 3 == 0 else { continue }
                    engine.draw(&rgba)
                    reached.add(rgba)
                }
            }
        }
        XCTAssertFalse(reached.isEmpty, "he never rested")
        let rest = reached.rect
        XCTAssertTrue(box.contains(rest), "at rest he reaches \(rest), outside the box \(box)")
        // Two pixels round him and no more, so the box is his rest and not a guess.
        XCTAssertEqual(box, rest.insetBy(dx: -2, dy: -2), "the box is not his rest with two pixels round it")
    }

    /// How far past the box each other pose reaches — work, the walk, the corner, yoga and the
    /// sign — recorded and not held: those are drawn over whatever is there, and he comes back.
    func testWhatReachesPastTheBoxIsRecorded() {
        let box = MascotSprite.box
        for activity in ["corner", "yoga", "thinking", "searching", "building", "writing", "calendar", "walk", "sign"] {
            var reached = Reach()
            for model in ["claude-haiku-4-5", "claude-opus-5", "claude-fable-5-1"] {
                // A random source of 0.05 sends him to yoga at the first excursion, 0.5 to the corner.
                let engine = Topo(random: { activity == "yoga" ? 0.05 : 0.5 })
                var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
                let excursion = activity == "yoga" || activity == "corner"
                for frame in 0..<((excursion ? 36 : 6) * 30) {
                    engine.update(1.0 / 30, TopoInput(model: model, tokens: 1_000,
                                                      activity: excursion ? "idle" : activity,
                                                      sign: activity == "sign" ? "updating memory" : nil,
                                                      corner: activity == "corner" ? 40 : 0))
                    guard frame % 6 == 0, !excursion || engine.outing != nil else { continue }
                    engine.draw(&rgba)
                    reached.add(rgba)
                }
            }
            let r = reached.rect
            let past = (left: max(0, box.minX - r.minX), top: max(0, box.minY - r.minY),
                        right: max(0, r.maxX - box.maxX), bottom: max(0, r.maxY - box.maxY))
            let line = "\(activity): past the box by \(Int(past.left)) left, \(Int(past.top)) up, "
                + "\(Int(past.right)) right, \(Int(past.bottom)) down, in art pixels"
            print("[topo-debug] mascot reach: \(line)")
            XCTContext.runActivity(named: line) { _ in }
        }
    }

    /// The union of the pixels drawn across frames of the engine's picture.
    private struct Reach {
        var x0 = Topo.width, y0 = Topo.height, x1 = -1, y1 = -1
        var isEmpty: Bool { x1 < 0 }
        var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1) }

        mutating func add(_ rgba: [UInt8]) {
            rgba.withUnsafeBufferPointer { pixels in
                for y in 0..<Topo.height {
                    for x in 0..<Topo.width where pixels[(y * Topo.width + x) * 4 + 3] > 0 {
                        x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                    }
                }
            }
        }
    }

    // MARK: The chat as drawn

    private let screen = CGSize(width: 402, height: 874)

    private struct Stage {
        let window: UIWindow
        let image: UIImage
        let canvas: MascotCanvas?
    }

    /// `atEnd` scrolls the transcript to its end, where the chat rests; a hosted window does not
    /// run the chat's own scroll to the newest turn.
    private func stage(_ turns: [Turn], mascot: Look.Mascot?, size: CGSize? = nil, atEnd: Bool = false) throws -> Stage {
        let screen = size ?? screen
        var look = Look()
        look.composer.surface = .flat
        if let mascot { look.mascot = mascot }
        let view = ChatCanvas(turns: turns, mascot: mascot == nil ? nil : MascotState(model: "claude-opus-5", activity: .searching))
            .environment(\.look, look)
            // A view hosted outside the app's scene reads as backgrounded, and he draws nothing there.
            .environment(\.scenePhase, .active)
            .transaction { $0.animation = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: screen)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.layoutIfNeeded()
        if atEnd, let scroll = find(UIScrollView.self, in: window) {
            let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: max(end, -scroll.adjustedContentInset.top)), animated: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            window.layoutIfNeeded()
        }
        let canvas = find(MascotCanvas.self, in: window)
        // The roam settled and a frame of him drawn, on the canvas's own clock.
        if let canvas { for _ in 0..<60 { canvas.step(1.0 / 30) } }
        CATransaction.flush()
        let image = UIGraphicsImageRenderer(size: screen).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return Stage(window: window, image: image, canvas: canvas)
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let view = view as? T { return view }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// Over an empty chat, a chat with room beside its turns and one with none, at the default
    /// look and the ends of the ranges for his size and clearance: he is drawn exactly where a
    /// roost holds him — at every look here but a scale of 4, whose 616-point picture no phone
    /// holds — and a look at which he is not drawn fails unless no roost holds him; his picture as the canvas draws it overlaps no
    /// turn and none of the pane, measured from the frames the views report as drawn; and every
    /// pixel of the pane is the same with him as without.
    func testTheChatAsDrawnHasHimClearOfEveryWordAndTheMicrophone() throws {
        for (name, turns, roost) in [("empty", [Turn](), "gap"), ("full", PreviewTurns.full, "gap"),
                                     ("fitting", PreviewTurns.fitting, nil)] as [(String, [Turn], String?)] {
            let without = try stage(turns, mascot: nil)
            defer { without.window.isHidden = true }
            XCTAssertNil(without.canvas)
            var looks = [Look.Mascot()]
            for (scale, clearance) in [(0.25, 0), (0.25, 64), (4, 0), (2.0 / 3, 8)] as [(CGFloat, CGFloat)] {
                var mascot = Look.Mascot()
                mascot.scale = scale
                mascot.clearance = clearance
                looks.append(mascot)
            }
            for mascot in looks {
                let label = "\(name), scale \(mascot.scale), clearance \(mascot.clearance)"
                let with = try stage(turns, mascot: mascot)
                defer { with.window.isHidden = true }
                let canvas = try XCTUnwrap(with.canvas, label)
                let roam = try XCTUnwrap(canvas.roam, label)
                let field = try XCTUnwrap(roam.field, "\(label): the chat reported no geometry")
                XCTAssertNotNil(field.pane, label)
                XCTAssertNotNil(field.well, label)
                if name != "empty" { XCTAssertFalse(field.obstacles.isEmpty, "\(label): no turn reported its frame") }
                if let roost, mascot == Look.Mascot() {
                    XCTAssertEqual(roam.roost.name, roost, label)
                    XCTAssertFalse(roam.hidden, label)
                }
                let expected = MascotRoost.of(field, size: MascotSprite.size(scale: mascot.scale),
                                              clearance: mascot.clearance, from: nil)
                XCTAssertEqual(roam.roost, expected, label)
                XCTAssertEqual(canvas.showing, expected != .none,
                               "\(label): drawn \(canvas.showing), where a roost \(expected.name == "none" ? "holds nothing" : "holds him")")
                // Every look here holds him but the largest in a full chat: a full chat holds him in
                // the margin beside its replies, and an empty one holds even the largest.
                let held = mascot.scale < 4 || name == "empty"
                XCTAssertEqual(canvas.showing, held, "\(label): \(expected.name)")
                if canvas.showing {
                    let drawn = canvas.spriteFrame
                    XCTAssertEqual(drawn.size, MascotSprite.size(scale: mascot.scale), label)
                    // The whole picture is drawn, its box where the roost has him.
                    let whole = canvas.drawnFrame
                    XCTAssertEqual(whole.width, CGFloat(Topo.width) * mascot.scale, accuracy: 0.001, label)
                    XCTAssertEqual(whole.height, CGFloat(Topo.height) * mascot.scale, accuracy: 0.001, label)
                    XCTAssertEqual(whole.minX + MascotSprite.box.minX * mascot.scale, drawn.minX, accuracy: 0.001, label)
                    XCTAssertEqual(whole.minY + MascotSprite.box.minY * mascot.scale, drawn.minY, accuracy: 0.001, label)
                    XCTAssertFalse(MascotRoost.overlap(drawn, field.well!), "\(label): drawn over the well")
                    XCTAssertFalse(MascotRoost.overlap(drawn, field.pane!), "\(label): drawn over the pane")
                    for obstacle in field.covering {
                        XCTAssertFalse(MascotRoost.overlap(drawn, obstacle), "\(label): drawn over \(obstacle)")
                    }
                }
                try assertPaneUnchanged(without, with, field: field, canvas: canvas, label)
            }
        }
    }

    /// The whole pane, pixel for pixel, with a shade for the render server's rounding on a curve's
    /// edge.
    private func assertPaneUnchanged(_ without: Stage, _ with: Stage, field: MascotField, canvas: MascotCanvas,
                                     _ label: String) throws {
        let controls = canvas.convert(try XCTUnwrap(field.pane), to: with.window)
            .intersection(CGRect(origin: .zero, size: screen))
        let bare = try LookStage.bytes(without.image)
        let drawn = try LookStage.bytes(with.image)
        let scale = Int(with.image.scale)
        let width = Int(screen.width) * scale
        var differing = 0
        for y in Int(controls.minY) * scale..<Int(controls.maxY) * scale {
            for x in Int(controls.minX) * scale..<Int(controls.maxX) * scale {
                let i = (y * width + x) * 4
                for c in 0..<4 where abs(Int(drawn[i + c]) - Int(bare[i + c])) > 2 { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0, "\(label): the pane changed with him over the chat")
    }

    /// A person's turn reports its bubble and not the row's width, so the room a short bubble
    /// leaves on its left is room. On the 393-point phone Sam's screenshot came from
    /// (`device-a70490e-trapped-on-flank.png`), the turn "Nothing, just testing the continuity
    /// feature :p" wraps to a bubble 294 points wide at x 83 — as drawn there — and the room left
    /// of it holds his picture 60 points wide with its clearance and not one 78 points wide. A
    /// narrower turn of two lines in the same place (`continuityShort`) leaves room a picture 74
    /// points wide fits.
    func testTheRoomBesideAShortBubbleIsAGap() throws {
        let phone = CGSize(width: 393, height: 852)
        let clearance = Look.Mascot().clearance
        /// His picture `width` points wide, left of `bubble` by the clearance and level with its middle.
        func beside(_ bubble: CGRect, width: CGFloat) -> CGRect {
            let size = MascotSprite.size(scale: width / MascotSprite.box.width)
            return CGRect(x: bubble.minX - clearance - size.width, y: bubble.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let screenshot = try stage(PreviewTurns.continuity, mascot: Look.Mascot(), size: phone)
        defer { screenshot.window.isHidden = true }
        let field = try XCTUnwrap(screenshot.canvas?.roam?.field)
        let bubble = try XCTUnwrap(field.obstacles.first { $0.minX > 40 }, "no turn reported less than the row: \(field.obstacles)")
        XCTAssertEqual(bubble.minX, 83, accuracy: 2, "the bubble is not where the phone drew it: \(bubble)")
        XCTAssertEqual(bubble.maxX, 377, accuracy: 2)
        XCTAssertTrue(MascotRoost.holds(field, frame: beside(bubble, width: 60), clearance: clearance),
                      "the room left of the bubble is not room: \(field.covering)")
        XCTAssertFalse(MascotRoost.holds(field, frame: beside(bubble, width: 78), clearance: clearance))

        let short = try stage(PreviewTurns.continuityShort, mascot: Look.Mascot(), size: phone)
        defer { short.window.isHidden = true }
        let shortField = try XCTUnwrap(short.canvas?.roam?.field)
        let shortBubble = try XCTUnwrap(shortField.obstacles.first { $0.minX > 150 }, "\(shortField.obstacles)")
        XCTAssertTrue(MascotRoost.holds(shortField, frame: beside(shortBubble, width: 74), clearance: clearance),
                      "the room left of the narrow bubble is not room: \(shortField.covering)")
    }

    /// Topo's reply reports its lines and not its frame, which is as wide as its widest line, and
    /// keeps a margin after them (`replyTrailingInset`, 150 points on the phone): with the
    /// column's padding, 166 points on the 393-point phone, it holds his picture at a scale of 1
    /// and its clearance from the words, flush with the screen's edge, and the ends of short lines
    /// add to it. `PreviewTurns.continuity` scrolled to its end, as the phone Sam's screenshot
    /// came from rests, and `PreviewTurns.ragged`, whose last reply ends in two short paragraphs,
    /// each hold him there, on the right, beside the reply.
    func testTheMarginBesideAReplyIsRoom() throws {
        let phone = CGSize(width: 393, height: 852)
        var original = Look.Mascot()
        original.scale = 1
        let clearance = original.clearance
        let size = MascotSprite.size(scale: 1)
        let look = Look()
        for (name, turns) in [("continuity", PreviewTurns.continuity), ("ragged", PreviewTurns.ragged)] {
            let chat = try stage(turns, mascot: original, size: phone, atEnd: true)
            defer { chat.window.isHidden = true }
            let field = try XCTUnwrap(chat.canvas?.roam?.field, name)
            let lines = field.covering.filter { $0.minX == 16 && $0.height > 18 && $0.height < 24 }
            XCTAssertGreaterThan(lines.count, 10, "\(name): Topo's replies did not report their lines: \(field.covering)")
            let edge = field.visible.maxX - look.transcript.horizontalPadding - look.transcript.replyTrailingInset
            XCTAssertLessThanOrEqual(lines.map(\.maxX).max() ?? 0, edge + 0.5, "\(name): a line ran into the margin")
            XCTAssertLessThanOrEqual(size.width + clearance, field.visible.maxX - edge, "\(name): the margin does not hold him")
            let spot = try XCTUnwrap(chat.canvas?.roam?.roost.frame, "\(name): he stands nowhere")
            XCTAssertEqual(chat.canvas?.roam?.roost.name, "gap", name)
            XCTAssertTrue(chat.canvas?.showing ?? false, name)
            XCTAssertGreaterThan(spot.midX, field.visible.midX, "\(name): not on the right: \(spot)")
            let alongside = lines.filter { $0.minY < spot.maxY + clearance && $0.maxY > spot.minY - clearance }
            XCTAssertFalse(alongside.isEmpty, "\(name): not beside the reply: \(spot)")
            for line in alongside {
                XCTAssertGreaterThanOrEqual(spot.minX, line.maxX + clearance - 0.001, "\(name): over \(line): \(spot)")
            }
            if name == "ragged" {
                let short = lines.sorted { $0.minY < $1.minY }.suffix(2)
                XCTAssertTrue(short.allSatisfy { $0.maxX < 150 }, "the two short paragraphs: \(lines)")
                for line in short {
                    XCTAssertTrue(spot.minY < line.maxY && spot.maxY > line.minY, "not beside \(line): \(spot)")
                }
            }
        }
    }

    /// With him drawn somewhere, the stage is different somewhere: the test above is not holding
    /// two pictures of nothing.
    func testHeIsDrawnAtAll() throws {
        for turns in [[], PreviewTurns.full] {
            let without = try stage(turns, mascot: nil)
            defer { without.window.isHidden = true }
            let with = try stage(turns, mascot: Look.Mascot())
            defer { with.window.isHidden = true }
            XCTAssertTrue(with.canvas?.showing ?? false)
            XCTAssertTrue(try LookStage.differ(try LookStage.bytes(without.image), try LookStage.bytes(with.image)),
                          "Topo drew nothing on the stage")
        }
    }
}
