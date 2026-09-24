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
/// it, is held to the same: his picture where the canvas draws it overlaps no turn, the well or
/// the flank beyond it, and the pane's controls are the same pixels with him as without.
///
/// That a press on the well reaches the microphone with him beside it is `TopoOnTheGlassTests`',
/// which presses it; neither stands in for the other.
@MainActor
final class MascotGeometryTests: XCTestCase {
    // MARK: Fixtures

    /// A phone's transcript, 402 points wide, over a pane 320 wide and 80 tall with its 72-point
    /// well in the middle: the leading flank is 124 by 80, which holds his picture at two thirds.
    static let visible = CGRect(x: 0, y: 0, width: 402, height: 628)
    static let pane = CGRect(x: 41, y: 540, width: 320, height: 80)
    static let well = CGRect(x: 165, y: 544, width: 72, height: 72)

    static func field(_ obstacles: [CGRect], keyboard: Bool = false) -> MascotField {
        if keyboard {
            // The keyboard is up from 400: the pane rides on it, short, and its flank is too short
            // for him.
            return MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 400), obstacles: obstacles,
                               pane: CGRect(x: 41, y: 344, width: 320, height: 53),
                               well: CGRect(x: 177, y: 345, width: 48, height: 48),
                               keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
        }
        return MascotField(visible: visible, obstacles: obstacles, pane: pane, well: well)
    }

    /// Rows down the transcript, alternating sides, each `height` tall with 12 between: the
    /// person's on the right from `personMinX`, Topo's on the left to `topoMaxX`.
    nonisolated static func rows(height: CGFloat, personMinX: CGFloat, topoMaxX: CGFloat, until bottom: CGFloat = 628) -> [CGRect] {
        var rows: [CGRect] = []
        var y: CGFloat = 12
        var mine = true
        while y < bottom {
            rows.append(mine ? CGRect(x: personMinX, y: y, width: 386 - personMinX, height: height)
                             : CGRect(x: 16, y: y, width: topoMaxX - 16, height: height))
            y += height + 12
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
        // Long turns on both sides, reaching under the pane as a scrolled transcript does.
        Fixture(name: "long turns on both sides", field: field(rows(height: 80, personMinX: 60, topoMaxX: 380, until: 700)),
                roost: "flank"),
        // Every row full width but one short person's turn on the right with room to its left.
        Fixture(name: "one gap only",
                field: field([CGRect(x: 16, y: 0, width: 370, height: 200),
                              CGRect(x: 250, y: 212, width: 136, height: 120),
                              CGRect(x: 16, y: 344, width: 370, height: 284)]),
                roost: "gap"),
        Fixture(name: "no gap", field: field([CGRect(x: 0, y: 0, width: 402, height: 628)]), roost: "flank"),
        Fixture(name: "the keyboard up, turns above it", field: field(rows(height: 40, personMinX: 300, topoMaxX: 150, until: 400),
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

    /// With no `from` he starts nearest the middle of the pane's leading flank, which is where he
    /// would otherwise sit.
    func testWithNowhereToStartFromHeStartsNearTheFlank() throws {
        let frame = try XCTUnwrap(MascotRoost.of(Self.fixtures[0].field, size: Self.size, clearance: 8, from: nil).frame)
        XCTAssertEqual(frame.maxY, Self.pane.minY - 8, accuracy: 0.001, "he does not stand just over the glass")
        XCTAssertEqual(frame.midX, Self.pane.minX + (Self.well.minX - Self.pane.minX) / 2, accuracy: 0.001)
    }

    /// The flank holds his whole picture or he is not drawn: at a scale the flank cannot hold, a
    /// chat with no gap has no Topo, never one over the microphone.
    func testAFlankThatCannotHoldHimDrawsNothing() {
        let noGap = Self.fixtures[3].field
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 1), clearance: 8, from: nil), .none)
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 4), clearance: 0, from: nil), .none)
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 0.25), clearance: 64, from: nil).name, "flank")
        var narrow = noGap
        narrow.well = CGRect(x: 60, y: 544, width: 72, height: 72)
        XCTAssertEqual(MascotRoost.of(narrow, size: Self.size, clearance: 8, from: nil), .none)
    }

    // MARK: The bounds, from geometry, at every end

    /// At every fixture, at the ends of the look's ranges for his size (0.25 and 4, and the
    /// default) and his clearance (0 and 64, and the default), from nowhere and from four corners:
    /// his whole picture — every point of it, top to bottom — overlaps no turn, no row, the well
    /// or the flank beyond it; standing in a gap it keeps the clearance from every turn and stays
    /// in the transcript above the glass; on the flank it is inside the flank.
    func testHisPictureExcludesEveryObstacleTheWellAndTheControlsAtEveryEnd() {
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
        let well = field.well ?? .null
        let controls = field.controls ?? .null
        XCTAssertFalse(MascotRoost.overlap(frame, well), "\(label): over the well", file: file, line: line)
        XCTAssertFalse(MascotRoost.overlap(frame, controls), "\(label): over the controls", file: file, line: line)
        for obstacle in field.obstacles where MascotRoost.overlap(obstacle, field.seen) {
            XCTAssertFalse(MascotRoost.overlap(frame, obstacle.intersection(field.seen)), "\(label): over \(obstacle)",
                           file: file, line: line)
        }
        switch roost {
        case .gap:
            let room = frame.insetBy(dx: -clearance, dy: -clearance)
            XCTAssertTrue(field.open.insetBy(dx: -0.001, dy: -0.001).contains(room), "\(label): out of the transcript",
                          file: file, line: line)
            for obstacle in field.covering {
                XCTAssertFalse(MascotRoost.overlap(room, obstacle), "\(label): within the clearance of \(obstacle)",
                               file: file, line: line)
            }
        case .flank:
            XCTAssertTrue(field.flank!.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(label): out of the flank",
                          file: file, line: line)
        case .none:
            break
        }
    }

    /// A line under the transcript — the error line, the one saying what is waiting, the offer
    /// card — is outside the transcript's frame and above the glass, and he is hidden over it as
    /// over a turn; a turn scrolled under the glass or the navigation bar is not over him.
    func testALineUnderTheTranscriptCoversHimAndTextUnderTheGlassDoesNot() {
        let field = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 500),
                                obstacles: [CGRect(x: 16, y: 510, width: 300, height: 20),
                                            CGRect(x: 16, y: 560, width: 370, height: 40),
                                            CGRect(x: 16, y: -60, width: 370, height: 50)],
                                pane: Self.pane, well: Self.well)
        XCTAssertTrue(field.covers(CGRect(x: 20, y: 480, width: 60, height: 40)), "the line under the transcript")
        XCTAssertFalse(field.covers(CGRect(x: 50, y: 560, width: 60, height: 40)), "a turn under the glass")
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

    /// Every pose on every head — yoga's lift and the sign included — is drawn inside
    /// `MascotSprite.box`, the part of the engine's picture the canvas shows: what is cut away is
    /// nothing, and the box a gap holds is the whole of him.
    func testEveryPoseIsDrawnInsideTheBox() {
        let box = MascotSprite.box
        for model in ["claude-haiku-4-5", "claude-opus-5", "claude-fable-5-1"] {
            for activity in ["yoga", "idle", "thinking", "searching", "building", "writing", "calendar", "walk", "sign"] {
                let engine = Topo(random: { activity == "yoga" ? 0.05 : 0.5 })
                var rgba = [UInt8](repeating: 0, count: Topo.width * Topo.height * 4)
                let seconds = activity == "yoga" ? 36 : activity == "idle" ? 32 : 6
                for frame in 0..<(seconds * 30) {
                    engine.update(1.0 / 30, TopoInput(model: model, tokens: 1_000,
                                                      activity: activity == "yoga" ? "idle" : activity,
                                                      sign: activity == "sign" ? "updating memory" : nil, corner: 0))
                    guard frame % 6 == 0 else { continue }
                    engine.draw(&rgba)
                    for y in 0..<Topo.height {
                        for x in 0..<Topo.width where rgba[(y * Topo.width + x) * 4 + 3] > 0 {
                            XCTAssertTrue(box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)),
                                          "\(model) \(activity): drawn at \(x),\(y), outside the box")
                            if !box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { return }
                        }
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

    private func stage(_ turns: [Turn], mascot: Look.Mascot?) throws -> Stage {
        var look = Look()
        look.composer.surface = .flat
        if let mascot { look.mascot = mascot }
        look.mascot.hideDuration = 0
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
    /// look and the ends of the ranges for his size and clearance: his picture as the canvas draws
    /// it overlaps no turn, the well or the flank beyond it, measured from the frames the views
    /// report as drawn; and every pixel of the pane from the well to its trailing end is the same
    /// with him as without.
    func testTheChatAsDrawnHasHimClearOfEveryWordAndTheMicrophone() throws {
        for (name, turns, roost) in [("empty", [Turn](), "gap"), ("full", PreviewTurns.full, "flank"),
                                     ("fitting", PreviewTurns.fitting, nil)] as [(String, [Turn], String?)] {
            let without = try stage(turns, mascot: nil)
            defer { without.window.isHidden = true }
            XCTAssertNil(without.canvas)
            var looks = [Look.Mascot()]
            for (scale, clearance) in [(0.25, 0), (0.25, 64), (4, 0), (1, 8)] as [(CGFloat, CGFloat)] {
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
                if canvas.showing {
                    let drawn = canvas.spriteFrame
                    XCTAssertEqual(drawn.size, MascotSprite.size(scale: mascot.scale), label)
                    XCTAssertFalse(MascotRoost.overlap(drawn, field.well!), "\(label): drawn over the well")
                    XCTAssertFalse(MascotRoost.overlap(drawn, field.controls!), "\(label): drawn over the controls")
                    for obstacle in field.covering {
                        XCTAssertFalse(MascotRoost.overlap(drawn, obstacle), "\(label): drawn over \(obstacle)")
                    }
                }
                try assertControlsUnchanged(without, with, field: field, canvas: canvas, label)
            }
        }
    }

    /// The pane from the well's leading edge to its trailing end, pixel for pixel, with a shade
    /// for the render server's rounding on a curve's edge.
    private func assertControlsUnchanged(_ without: Stage, _ with: Stage, field: MascotField, canvas: MascotCanvas,
                                         _ label: String) throws {
        let controls = canvas.convert(try XCTUnwrap(field.controls), to: with.window)
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
        XCTAssertEqual(differing, 0, "\(label): the pane's controls changed with him over the chat")
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
