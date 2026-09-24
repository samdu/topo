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
/// the flank before it, and the pane's controls are the same pixels with him as without.
///
/// That a press on the well reaches the microphone with him beside it is `TopoOnTheGlassTests`',
/// which presses it; neither stands in for the other.
@MainActor
final class MascotGeometryTests: XCTestCase {
    // MARK: Fixtures

    /// A phone's transcript, 402 points wide, over a pane 320 wide and 80 tall with its 72-point
    /// well in the middle: the trailing flank is 124 by 80, which holds his picture at two thirds.
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

    /// Of two places as near where he stands, the one on the right wins: a turn down the middle
    /// with room either side of it, and him over it.
    func testATieGoesToTheRight() throws {
        let field = Self.field([CGRect(x: 151, y: 0, width: 100, height: 628)])
        let from = CGPoint(x: 201 - Self.size.width / 2, y: 100)
        let frame = try XCTUnwrap(MascotRoost.of(field, size: Self.size, clearance: 8, from: from).frame)
        XCTAssertEqual(frame.minX, 251 + 8, accuracy: 0.001, "he went left: \(frame)")
        XCTAssertEqual(frame.minY, 100, accuracy: 0.001)
    }

    /// With no `from` he starts nearest the middle of the pane's trailing flank, which is where he
    /// would otherwise sit.
    func testWithNowhereToStartFromHeStartsNearTheFlank() throws {
        let frame = try XCTUnwrap(MascotRoost.of(Self.fixtures[0].field, size: Self.size, clearance: 8, from: nil).frame)
        XCTAssertEqual(frame.maxY, Self.pane.minY - 8, accuracy: 0.001, "he does not stand just over the glass")
        XCTAssertEqual(frame.midX, Self.well.maxX + (Self.pane.maxX - Self.well.maxX) / 2, accuracy: 0.001)
    }

    /// The flank holds his whole picture or he is not drawn: at a scale the flank cannot hold, a
    /// chat with no gap has no Topo, never one over the microphone.
    func testAFlankThatCannotHoldHimDrawsNothing() {
        let noGap = Self.fixtures[3].field
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 1), clearance: 8, from: nil), .none)
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 4), clearance: 0, from: nil), .none)
        XCTAssertEqual(MascotRoost.of(noGap, size: MascotSprite.size(scale: 0.25), clearance: 64, from: nil).name, "flank")
        var narrow = noGap
        narrow.well = CGRect(x: 270, y: 544, width: 72, height: 72)
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
    /// card — is outside the transcript's frame and above the glass, and it covers him as a turn
    /// does; a turn scrolled under the glass or the navigation bar is not over him.
    func testALineUnderTheTranscriptCoversHimAndTextUnderTheGlassDoesNot() {
        let field = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 500),
                                obstacles: [CGRect(x: 16, y: 510, width: 300, height: 20),
                                            CGRect(x: 16, y: 560, width: 370, height: 40),
                                            CGRect(x: 16, y: -60, width: 370, height: 50)],
                                pane: Self.pane, well: Self.well)
        XCTAssertTrue(field.covers(CGRect(x: 20, y: 480, width: 60, height: 40)), "the line under the transcript")
        XCTAssertFalse(field.covers(CGRect(x: 290, y: 560, width: 60, height: 40)), "a turn under the glass")
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
    /// holds, and a scale of 1 over a chat with no gap, whose flank is narrower than he is — and a look at which he is not drawn fails unless no roost holds him; his picture as
    /// the canvas draws it overlaps no turn, the well or the flank beyond it, measured from the
    /// frames the views report as drawn; and every pixel of the pane from the well to its trailing
    /// end is the same with him as without.
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
                let expected = MascotRoost.of(field, size: MascotSprite.size(scale: mascot.scale),
                                              clearance: mascot.clearance, from: nil)
                XCTAssertEqual(roam.roost, expected, label)
                XCTAssertEqual(canvas.showing, expected != .none,
                               "\(label): drawn \(canvas.showing), where a roost \(expected.name == "none" ? "holds nothing" : "holds him")")
                // Every look here holds him but the largest, and a scale of 1 over a chat with no
                // gap, whose flank is narrower than his 154 points.
                let held = mascot.scale < 4 && !(name == "full" && mascot.scale >= 1)
                XCTAssertEqual(canvas.showing, held, "\(label): \(expected.name)")
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

    /// The pane from its leading end to the well's trailing edge, pixel for pixel, with a shade
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
    /// A person's turn reports its bubble and not the row's width, so the room a short bubble
    /// leaves on its left is room. On the 393-point phone Sam's screenshot came from
    /// (`device-a70490e-trapped-on-flank.png`), the turn "Nothing, just testing the continuity
    /// feature :p" wraps to a bubble 294 points wide at x 83 — as drawn there — and the room left
    /// of it, 83 points, is narrower than his picture at the default look (103 points, 119 with
    /// its clearance), so no roost holds him there and he is on the flank; at a scale whose
    /// picture fits that room he stands in it. A narrower turn of two lines in the same place
    /// leaves room his default picture fits — a one-line bubble's row, about 85 points with the
    /// spacing either side, is shorter than his 91 — and he takes it.
    func testTheRoomBesideAShortBubbleIsAGap() throws {
        let phone = CGSize(width: 393, height: 852)
        let screenshot = try stage(PreviewTurns.continuity, mascot: Look.Mascot(), size: phone)
        defer { screenshot.window.isHidden = true }
        let field = try XCTUnwrap(screenshot.canvas?.roam?.field)
        let bubble = try XCTUnwrap(field.obstacles.first { $0.minX > 40 }, "no turn reported less than the row: \(field.obstacles)")
        XCTAssertEqual(bubble.minX, 83, accuracy: 2, "the bubble is not where the phone drew it: \(bubble)")
        XCTAssertEqual(bubble.maxX, 377, accuracy: 2)
        let size = MascotSprite.size(scale: Look.Mascot().scale)
        XCTAssertLessThan(bubble.minX, size.width + 2 * Look.Mascot().clearance, "the room left of it holds him")
        XCTAssertEqual(screenshot.canvas?.roam?.roost.name, "flank")

        var small = Look.Mascot()
        small.scale = 0.4
        let fits = try stage(PreviewTurns.continuity, mascot: small, size: phone)
        defer { fits.window.isHidden = true }
        let roost = try XCTUnwrap(fits.canvas?.roam?.roost.frame, "at a scale of 0.4 he stands nowhere")
        XCTAssertLessThanOrEqual(roost.maxX, bubble.minX - small.clearance + 0.001, "not beside the bubble: \(roost)")
        XCTAssertTrue(roost.minY < bubble.maxY && roost.maxY > bubble.minY, "not beside the bubble: \(roost) \(bubble)")

        let short = try stage(PreviewTurns.continuityShort, mascot: Look.Mascot(), size: phone)
        defer { short.window.isHidden = true }
        let shortField = try XCTUnwrap(short.canvas?.roam?.field)
        let shortBubble = try XCTUnwrap(shortField.obstacles.first { $0.minX > 150 }, "\(shortField.obstacles)")
        let beside = try XCTUnwrap(short.canvas?.roam?.roost.frame, "he stands nowhere")
        XCTAssertEqual(short.canvas?.roam?.roost.name, "gap")
        XCTAssertLessThanOrEqual(beside.maxX, shortBubble.minX - 8 + 0.001, "not beside the bubble: \(beside) \(shortBubble)")
        XCTAssertTrue(beside.minY < shortBubble.maxY && beside.maxY > shortBubble.minY,
                      "not beside the bubble: \(beside) \(shortBubble)")
        XCTAssertTrue(short.canvas?.showing ?? false)
    }

    /// Topo's reply reports its lines and not its frame, which is as wide as its widest line, so
    /// the room at the end of a short line is room, and of two places as near each other he takes
    /// the one on the right. `PreviewTurns.continuity` scrolled to its end, as the phone Sam's
    /// screenshot came from rests: the last line, "…has to mean here.", ends 100 points
    /// short of the transcript's edge, and the room beside it and its time, down to the
    /// transcript's foot, is 100 by 52 points, smaller both ways than his 103-by-75 picture with
    /// its clearance, so he is on the trailing flank; at a scale whose picture that room holds, he stands in it. In
    /// `PreviewTurns.ragged` the reply ends in two short paragraphs, and the room at their end, on
    /// the right, is where he stands at the default look.
    func testTheRaggedRightOfAReplyIsRoom() throws {
        let phone = CGSize(width: 393, height: 852)
        let clearance = Look.Mascot().clearance
        let size = MascotSprite.size(scale: Look.Mascot().scale)

        let screenshot = try stage(PreviewTurns.continuity, mascot: Look.Mascot(), size: phone, atEnd: true)
        defer { screenshot.window.isHidden = true }
        let field = try XCTUnwrap(screenshot.canvas?.roam?.field)
        let lines = field.covering.filter { $0.minX == 16 && $0.height > 18 && $0.height < 24 }
        XCTAssertGreaterThan(lines.count, 10, "Topo's replies did not report their lines: \(field.covering)")
        let last = try XCTUnwrap(lines.max { $0.minY < $1.minY })
        let above = try XCTUnwrap(lines.filter { $0.maxY <= last.minY }.max { $0.minY < $1.minY })
        XCTAssertLessThan(last.maxX, above.maxX - 50, "the last line is not short: \(last), \(above)")
        let room = CGRect(x: last.maxX, y: above.maxY, width: field.visible.maxX - last.maxX, height: field.open.maxY - above.maxY)
        XCTAssertLessThan(room.width, size.width + 2 * clearance, "\(room)")
        XCTAssertLessThan(room.height, size.height + 2 * clearance, "\(room)")
        let roost = try XCTUnwrap(screenshot.canvas?.roam?.roost)
        XCTAssertEqual(roost.name, "flank")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(roost.frame).minX, try XCTUnwrap(field.well).maxX - 0.001, "not on the right")

        var small = Look.Mascot()
        small.scale = 0.3
        let fits = try stage(PreviewTurns.continuity, mascot: small, size: phone, atEnd: true)
        defer { fits.window.isHidden = true }
        let tail = try XCTUnwrap(fits.canvas?.roam?.roost.frame, "at a scale of 0.3 he stands nowhere")
        XCTAssertEqual(fits.canvas?.roam?.roost.name, "gap")
        XCTAssertGreaterThanOrEqual(tail.minX, last.maxX + small.clearance - 0.001, "not after the last line: \(tail)")
        XCTAssertTrue(tail.minY < last.maxY && tail.maxY > last.minY, "not beside the last line: \(tail) \(last)")

        let ragged = try stage(PreviewTurns.ragged, mascot: Look.Mascot(), size: phone, atEnd: true)
        defer { ragged.window.isHidden = true }
        let raggedField = try XCTUnwrap(ragged.canvas?.roam?.field)
        let short = raggedField.covering.filter { $0.minX == 16 && $0.height > 18 && $0.height < 24 && $0.maxX < 150 }
        XCTAssertEqual(short.count, 2, "the two short paragraphs: \(raggedField.covering)")
        let spot = try XCTUnwrap(ragged.canvas?.roam?.roost.frame, "he stands nowhere")
        XCTAssertEqual(ragged.canvas?.roam?.roost.name, "gap")
        XCTAssertTrue(ragged.canvas?.showing ?? false)
        for line in short {
            XCTAssertTrue(spot.minY < line.maxY && spot.maxY > line.minY, "not beside \(line): \(spot)")
            XCTAssertGreaterThanOrEqual(spot.minX, line.maxX + clearance - 0.001, "over \(line): \(spot)")
        }
        XCTAssertGreaterThan(spot.midX, raggedField.visible.midX, "not on the right: \(spot)")
    }

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
