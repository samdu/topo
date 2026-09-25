import CoreGraphics
import TopoMascot
import UIKit
import XCTest

@testable import Topo

/// Where Topo sits is a policy (`Look.Mascot.placement`): roaming the gaps, on the glass, or at a
/// pin. Each is held here over the chat's geometry as the simulator reports it for a 402-point
/// phone — an empty chat, a full one, and the keyboard up — and the ways between them: a change
/// of policy is a glide, the keyboard lifts a pinned Topo only while it is up, and a drag pins him
/// where it lets go.
@MainActor
final class MascotPlacementTests: XCTestCase {
    static let scale: CGFloat = 1
    static let size = MascotSprite.size(scale: scale)
    static let reach = MascotSprite.reach(scale: scale)
    static let frame = 1.0 / 30

    /// The transcript ends above the lines under it; the pane below, with its well in the middle.
    static let visible = CGRect(x: 0, y: 0, width: 402, height: 586)
    static let pane = CGRect(x: 40, y: 636, width: 321, height: 80)
    static let well = CGRect(x: 165, y: 640, width: 72, height: 72)

    static func settings(_ placement: Look.Mascot.Placement, pin: CGPoint = Look.Mascot().pin,
                         reduceMotion: Bool = false) -> MascotRoam.Settings {
        MascotRoam.Settings(size: size, clearance: 8, reach: reach, speed: 40, hurry: 10, settle: 0.6,
                            reduceMotion: reduceMotion, placement: placement, pin: pin)
    }

    /// An empty chat, a full one — words down the whole column — and either with the keyboard up,
    /// the pane riding on it short and the transcript ending above it.
    static func field(full: Bool = false, keyboard: Bool = false) -> MascotField {
        let words = full ? stride(from: 12.0, to: 580, by: 44).map { CGRect(x: 16, y: $0, width: 370, height: 32) } : []
        guard keyboard else { return MascotField(visible: visible, obstacles: words, pane: pane, well: well) }
        return MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 330), obstacles: words.filter { $0.maxY < 330 },
                           pane: CGRect(x: 40, y: 344, width: 321, height: 53),
                           well: CGRect(x: 177, y: 346, width: 48, height: 48),
                           keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
    }

    /// A roam under `settings` handed `fields` in turn, each left to settle.
    private func settled(_ settings: MascotRoam.Settings, _ fields: [MascotField], time: inout Double) -> MascotRoam {
        var roam = MascotRoam(settings, frame: Self.frame)
        for field in fields { run(&roam, field, time: &time) }
        return roam
    }

    private func run(_ roam: inout MascotRoam, _ field: MascotField? = nil, time: inout Double, for seconds: Double = 60) {
        if let field { roam.observe(field, at: time) }
        let until = time + seconds
        repeat {
            time += Self.frame
            roam.advance(to: time)
        } while roam.needsTime && time < until
    }

    // MARK: Glass

    /// On the glass he stands in the empty flank — the trailing one, the keyboard's control being
    /// the leading one's — his body in the middle of it and the engine's shelf on the pane's top
    /// edge, over an empty chat, a full one, and on the short pane with the keyboard up, where he
    /// is put at once as the pane moves: he rides it, with no glide and no settle. Words are not
    /// his to keep clear of there, so nothing is over him; he faces right, his centre being right
    /// of the transcript's middle.
    func testOnTheGlassHeSitsInTheEmptyFlankAndRidesThePane() throws {
        var time = 0.0
        var roam = MascotRoam(Self.settings(.glass), frame: Self.frame)
        for (label, field) in [("empty", Self.field()), ("full", Self.field(full: true)),
                               ("keyboard up", Self.field(keyboard: true)), ("full, keyboard up", Self.field(full: true, keyboard: true)),
                               ("keyboard down", Self.field())] {
            let moves = roam.moves
            roam.observe(field, at: time)
            // At once: the geometry it arrives in, before any tick of the clock.
            let box = try XCTUnwrap(roam.picture, label)
            let pane = try XCTUnwrap(field.pane), well = try XCTUnwrap(field.well)
            XCTAssertEqual(roam.roost.name, "glass", label)
            XCTAssertEqual(roam.moves, moves, "\(label): he glided rather than riding the pane")
            XCTAssertFalse(roam.walking, label)
            XCTAssertEqual(box.minY + (CGFloat(Topo.shelfY) - MascotSprite.box.minY) * Self.scale, pane.minY,
                           accuracy: 0.001, "\(label): his shelf is not the pane's top edge")
            XCTAssertEqual(box.midX, (well.maxX + pane.maxX) / 2, accuracy: 0.001, "\(label): not in the middle of the flank")
            XCTAssertGreaterThanOrEqual(box.minX, well.maxX, "\(label): his box is over the well")
            XCTAssertLessThanOrEqual(box.maxX, pane.maxX, "\(label): his box runs off the pane")
            // What he is drawn in on the glass is the flank and nothing of the well.
            let slot = try XCTUnwrap(MascotPerch.glassSlot(field))
            XCTAssertFalse(MascotRoost.overlap(slot, well), label)
            XCTAssertEqual(slot.maxY, pane.maxY, accuracy: 0.001, label)
            XCTAssertTrue(slot.contains(CGPoint(x: box.midX, y: 0)), "\(label): the slot does not reach the top of the screen")
            XCTAssertFalse(roam.covered, "\(label): words or glass counted over him on the glass")
            XCTAssertEqual(roam.facing, .right, label)
            run(&roam, time: &time, for: 2)
            XCTAssertEqual(roam.picture, box, "\(label): he moved off the glass on the clock")
        }
        XCTAssertEqual(roam.moves, 0)
    }

    /// With no pane to sit on he stands nowhere and is not drawn.
    func testOnTheGlassWithNoPaneHeIsNotDrawn() {
        var roam = MascotRoam(Self.settings(.glass), frame: Self.frame)
        roam.observe(MascotField(visible: Self.visible), at: 0)
        XCTAssertTrue(roam.hidden)
        XCTAssertEqual(roam.roost, .none)
    }

    // MARK: Pinned

    /// Pinned, his box's centre is the pin — a fraction across and down the transcript's frame
    /// carried to the pane's foot — over an empty chat and a full one alike: the words are not
    /// obstacles, and nothing is over him, since a person put him there. He faces the half his
    /// centre is in.
    func testPinnedHisCentreIsThePinWhateverTheWords() throws {
        let within = Self.field().pinFrame
        XCTAssertEqual(within, CGRect(x: 0, y: 0, width: 402, height: 716), "the frame a pin is a fraction of")
        for full in [false, true] {
            for pin in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.25), CGPoint(x: 0.5, y: 0.6)] {
                var time = 0.0
                let roam = settled(Self.settings(.pinned, pin: pin), [Self.field(full: full)], time: &time)
                let box = try XCTUnwrap(roam.picture)
                XCTAssertEqual(box.midX, within.minX + pin.x * within.width, accuracy: 0.001, "\(pin), full \(full)")
                XCTAssertEqual(box.midY, within.minY + pin.y * within.height, accuracy: 0.001, "\(pin), full \(full)")
                XCTAssertEqual(roam.roost.name, "pinned")
                XCTAssertFalse(roam.covered, "words counted over a pinned Topo")
                XCTAssertEqual(roam.moves, 0, "the first placement glided")
                XCTAssertEqual(roam.facing, pin.x > 0.5 ? .right : .left, "\(pin)")
            }
        }
    }

    /// A pin at the frame's corners, or one outside `0...1` handed straight to the roam, keeps his
    /// whole reach inside the frame: the screen's edge holds him wherever the pin is.
    func testAPinAtOrPastTheEdgeKeepsHisReachInsideTheFrame() throws {
        let within = Self.field().pinFrame
        let pins = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0),
                    CGPoint(x: 5, y: -3), CGPoint(x: -1, y: 9), CGPoint(x: CGFloat.nan, y: CGFloat.infinity)]
        for pin in pins {
            var time = 0.0
            let roam = settled(Self.settings(.pinned, pin: pin), [Self.field()], time: &time)
            let box = try XCTUnwrap(roam.picture, "\(pin)")
            XCTAssertTrue(within.insetBy(dx: -0.001, dy: -0.001).contains(Self.reach.around(box)),
                          "\(pin): his reach \(Self.reach.around(box)) is outside \(within)")
            XCTAssertTrue(box.minX.isFinite && box.minY.isFinite, "\(pin)")
        }
    }

    /// The keyboard coming up over a pinned Topo lifts him clear of it at the hurry, keeping his
    /// clearance or his reach from its top edge; the pin he goes back to is the keyboard-down
    /// frame's and is never rewritten; the keyboard going sends him back to it at the stroll,
    /// to the very frame he stood in.
    func testTheKeyboardLiftsAPinnedTopoAndHeGoesBackToThePin() throws {
        let pin = CGPoint(x: 0.8, y: 0.85)
        var time = 0.0
        var roam = settled(Self.settings(.pinned, pin: pin), [Self.field()], time: &time)
        let home = try XCTUnwrap(roam.picture)
        let resting = try XCTUnwrap(roam.resting)

        let up = Self.field(keyboard: true)
        roam.observe(up, at: time)
        let lift = try XCTUnwrap(roam.move, "the keyboard came up over him and he did not go")
        XCTAssertEqual(lift.pace, 10, "not at the hurry")
        XCTAssertEqual(roam.moves, 1)
        run(&roam, time: &time)
        let lifted = try XCTUnwrap(roam.picture)
        let keyboard = try XCTUnwrap(up.keyboard)
        XCTAssertLessThanOrEqual(lifted.maxY + max(8, Self.reach.bottom), keyboard.minY + 0.001, "still over the keyboard")
        XCTAssertEqual(lifted.midX, home.midX, accuracy: 0.001, "the lift moved him across")
        XCTAssertEqual(roam.settings.pin, pin, "the keyboard rewrote the pin")
        XCTAssertEqual(roam.resting, resting, "the keyboard moved the frame the pin is read in")

        roam.observe(Self.field(), at: time)
        let back = try XCTUnwrap(roam.move, "the keyboard went and he stayed lifted")
        XCTAssertEqual(back.pace, 1, "not at the stroll")
        run(&roam, time: &time)
        XCTAssertEqual(roam.picture, home, "not back at the pin")
        XCTAssertEqual(roam.settings.pin, pin)
    }

    // MARK: Between policies

    /// A change of policy is one glide from where he is to where the new one puts him, at the
    /// stroll, as a roost change is: roaming to the glass, the glass to a pin, and the pin back to
    /// roaming, which decides a roost from where he stands — the nearest gap to him.
    func testAChangeOfPolicyIsAGlideAtTheStroll() throws {
        var time = 0.0
        let field = Self.field()
        var roam = settled(Self.settings(.roam), [field], time: &time)
        XCTAssertEqual(roam.roost.name, "gap")
        for (placement, name) in [(Look.Mascot.Placement.glass, "glass"), (.pinned, "pinned")] {
            let from = try XCTUnwrap(roam.position)
            let moves = roam.moves
            roam.use(Self.settings(placement, pin: CGPoint(x: 0.2, y: 0.3)))
            let glide = try XCTUnwrap(roam.move, "\(name): placed rather than glided")
            XCTAssertEqual(glide.from, from, name)
            XCTAssertEqual(glide.pace, 1, name)
            XCTAssertEqual(glide.duration, Double(hypot(glide.to.x - from.x, glide.to.y - from.y) / 40), accuracy: 1e-9, name)
            XCTAssertEqual(roam.moves, moves + 1, name)
            XCTAssertEqual(roam.roost.name, name)
            run(&roam, time: &time)
            XCTAssertEqual(roam.position, glide.to, name)
        }
        // Pinned among the words, roaming takes him from where he stands to the nearest gap to him,
        // in the margin the words leave on the right.
        var full = Self.field()
        full.obstacles = stride(from: 12.0, to: 580, by: 44).map { CGRect(x: 16, y: $0, width: 234, height: 32) }
        roam.observe(full, at: time)
        let pinned = try XCTUnwrap(roam.position)
        roam.use(Self.settings(.roam))
        // The roam's own decision from where he stands: a word over him sends him to its far side,
        // so the gap is the roam's, and it is a gap, reached by a glide from the pin.
        let gap = try XCTUnwrap(roam.roost.frame, "from a pin, roaming put him nowhere")
        XCTAssertEqual(roam.roost.name, "gap")
        XCTAssertTrue(MascotRoost.holds(full, frame: gap, clearance: 8, reach: Self.reach), "\(gap) is not a gap")
        let glide = try XCTUnwrap(roam.move, "from a pin to roaming, placed rather than glided")
        XCTAssertEqual(glide.from, pinned)
        run(&roam, time: &time)
        XCTAssertEqual(roam.picture, gap)
    }

    /// A new pin is the same: a glide to it. Under Reduce Motion, a change of policy places him at
    /// once.
    func testANewPinIsAGlideAndReduceMotionPlacesHimAtOnce() throws {
        var time = 0.0
        var roam = settled(Self.settings(.pinned, pin: CGPoint(x: 0.2, y: 0.2)), [Self.field()], time: &time)
        roam.use(Self.settings(.pinned, pin: CGPoint(x: 0.8, y: 0.6)))
        XCTAssertNotNil(roam.move)
        run(&roam, time: &time)

        var still = settled(Self.settings(.roam, reduceMotion: true), [Self.field()], time: &time)
        still.use(Self.settings(.glass, reduceMotion: true))
        XCTAssertNil(still.move)
        XCTAssertEqual(still.picture, MascotPerch.glass(Self.field(), size: Self.size))
    }

    // MARK: A drag

    /// A drag: picked up on his box, never on the well, carried at his size wherever the finger
    /// takes him with nothing decided on the way — a geometry arriving mid-drag moves nothing — and
    /// let go, which pins him there: the pin is where his centre is in the keyboard-down frame, the
    /// policy is `pinned` from that moment, and the clock moves him nowhere after it.
    func testADragPinsHimWhereItLetsGo() throws {
        var time = 0.0
        var roam = settled(Self.settings(.roam), [Self.field()], time: &time)
        let start = try XCTUnwrap(roam.picture)
        XCTAssertTrue(roam.grabbable(at: CGPoint(x: start.midX, y: start.midY)))
        XCTAssertFalse(roam.grabbable(at: CGPoint(x: start.maxX + 5, y: start.midY)), "off his box")
        XCTAssertTrue(roam.grab())
        XCTAssertEqual(roam.drags, 1)
        roam.drag(to: CGPoint(x: 60, y: 200))
        XCTAssertEqual(roam.picture?.origin, CGPoint(x: 60, y: 200))
        roam.observe(Self.field(full: true), at: time)
        run(&roam, time: &time, for: 2)
        XCTAssertEqual(roam.picture?.origin, CGPoint(x: 60, y: 200), "a geometry moved him in the finger")
        XCTAssertEqual(roam.facing, .left, "he did not turn crossing the middle")
        let pin = try XCTUnwrap(roam.drop())
        let within = Self.field().pinFrame
        XCTAssertEqual(pin.x, (60 + Self.size.width / 2) / within.width, accuracy: 1e-9)
        XCTAssertEqual(pin.y, (200 + Self.size.height / 2) / within.height, accuracy: 1e-9)
        XCTAssertEqual(roam.settings.placement, .pinned)
        XCTAssertEqual(roam.settings.pin, pin)
        XCTAssertFalse(roam.dragging)
        run(&roam, time: &time)
        XCTAssertEqual(roam.picture?.origin, CGPoint(x: 60, y: 200), "the pin did not hold him where he was let go")
        // The look catching up with the same pin moves nothing.
        roam.use(Self.settings(.pinned, pin: pin))
        XCTAssertNil(roam.move)
        XCTAssertEqual(roam.picture?.origin, CGPoint(x: 60, y: 200))
    }

    /// A finger carrying him off the screen's edge takes him only as far as his reach stays inside
    /// the frame, and that is where he is pinned.
    func testADragPastTheEdgeStopsAtIt() throws {
        var time = 0.0
        var roam = settled(Self.settings(.roam), [Self.field()], time: &time)
        XCTAssertTrue(roam.grab())
        roam.drag(to: CGPoint(x: 900, y: -400))
        let box = try XCTUnwrap(roam.picture)
        let within = Self.field().pinFrame
        XCTAssertTrue(within.insetBy(dx: -0.001, dy: -0.001).contains(Self.reach.around(box)), "\(box)")
        let pin = try XCTUnwrap(roam.drop())
        XCTAssertTrue((0...1).contains(pin.x) && (0...1).contains(pin.y), "\(pin)")
    }

    /// Pinned over the well, he can be picked up by his box and not by the well: a press on the
    /// well is the microphone's whatever is drawn over it. He is drawn over the well, and not
    /// covered by it.
    func testOverTheWellThePressIsTheMicrophones() throws {
        let field = Self.field()
        let within = field.pinFrame
        let pin = CGPoint(x: Self.well.midX / within.width, y: Self.well.midY / within.height)
        var time = 0.0
        let roam = settled(Self.settings(.pinned, pin: pin), [field], time: &time)
        let box = try XCTUnwrap(roam.picture)
        XCTAssertTrue(MascotRoost.overlap(box, Self.well), "not over the well: \(box)")
        XCTAssertFalse(roam.grabbable(at: CGPoint(x: Self.well.midX, y: Self.well.midY)), "the well's middle")
        XCTAssertFalse(roam.grabbable(at: CGPoint(x: Self.well.maxX - 1, y: Self.well.minY + 1)), "the well's corner")
        XCTAssertTrue(roam.grabbable(at: CGPoint(x: box.minX + 2, y: box.minY + 2)), "his box off the well")
        XCTAssertFalse(roam.covered)
    }

    /// Nothing is picked up where he is not drawn.
    func testNothingIsPickedUpWhereHeIsNotDrawn() {
        var roam = MascotRoam(Self.settings(.roam), frame: Self.frame)
        XCTAssertFalse(roam.grab())
        XCTAssertEqual(roam.drags, 0)
        XCTAssertNil(roam.drop())
    }

    // MARK: The canvas

    private let seen = MascotDriver.Conditions(active: true, onScreen: true, opacity: 1, covered: false,
                                               reduceMotion: false)

    /// The canvas drags him as the recognizer does, and hands the pin to whoever keeps it; a press
    /// starting on the well hands nothing. The recognizer lives on the window the canvas is in, and
    /// is handed only touches the canvas would pick him up by.
    func testTheCanvasHandsTheDragsPinOnAndNotTheWells() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.isHidden = false
        defer { window.isHidden = true }
        let canvas = MascotCanvas(frame: window.bounds)
        window.addSubview(canvas)
        XCTAssertTrue(window.gestureRecognizers?.contains(canvas.grab) ?? false, "the recognizer is not on the window")
        var pinned: [CGPoint] = []
        canvas.onPin = { pinned.append($0) }
        let field = Self.field()
        let within = field.pinFrame
        let overWell = CGPoint(x: Self.well.midX / within.width, y: Self.well.midY / within.height)
        canvas.apply(input: MascotState(model: "claude-sonnet-5").input, field: field,
                     settings: Self.settings(.pinned, pin: overWell), interval: Self.frame, conditions: seen)
        canvas.step(Self.frame)
        XCTAssertTrue(canvas.showing)
        XCTAssertNil(canvas.drag(from: CGPoint(x: Self.well.midX, y: Self.well.midY), to: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(pinned, [])
        XCTAssertEqual(canvas.roam?.drags, 0, "a press on the well began a drag")
        let box = canvas.spriteFrame
        let pin = try XCTUnwrap(canvas.drag(from: CGPoint(x: box.minX + 4, y: box.minY + 4), to: CGPoint(x: 104, y: 204)))
        XCTAssertEqual(pinned, [pin])
        XCTAssertEqual(canvas.spriteFrame.origin, CGPoint(x: 100, y: 200))
        canvas.removeFromSuperview()
        XCTAssertFalse(window.gestureRecognizers?.contains(canvas.grab) ?? false, "the recognizer outlived the canvas")
    }

    /// On the glass the picture is drawn inside the empty flank only: nothing of it over the well.
    func testOnTheGlassNothingOfHimIsDrawnOverTheWell() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let field = Self.field()
        canvas.apply(input: MascotState(model: "claude-sonnet-5").input, field: field,
                     settings: Self.settings(.glass), interval: Self.frame, conditions: seen)
        canvas.step(Self.frame)
        let shown = canvas.shownFrame
        XCTAssertFalse(shown.isEmpty)
        XCTAssertGreaterThanOrEqual(shown.minX, Self.well.maxX - 0.001, "drawn over the well: \(shown)")
        XCTAssertLessThanOrEqual(shown.maxX, Self.pane.maxX + 0.001, "drawn off the pane's end: \(shown)")
        XCTAssertLessThan(canvas.drawnFrame.minX, Self.well.maxX, "the whole picture would reach the well, so the clip is what is held")
    }
}
