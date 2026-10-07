import SwiftUI
import TopoMascot
import TopoTurn
import UIKit
import XCTest

@testable import Topo

/// The model slider on the glass and Topo over it: which stop a finger on the line is nearest,
/// where he sits while the slider is open, that he glides there, along it and away again rather
/// than being put, and, in a hosted chat, that he is drawn over the stop chosen.
@MainActor
final class ModelSliderTests: XCTestCase {
    static let size = MascotSprite.size(scale: 1)
    static let reach = MascotSprite.reach(scale: 1)
    static let frame = 1.0 / 30

    static let visible = CGRect(x: 0, y: 0, width: 402, height: 586)
    static let pane = CGRect(x: 40, y: 636, width: 321, height: 80)
    static let well = CGRect(x: 165, y: 640, width: 72, height: 72)
    /// The pane with the slider open across its top, and the three stops' columns on it.
    static let openPane = CGRect(x: 40, y: 590, width: 321, height: 126)
    static let stops = [80.0, 200.5, 321.0].map { CGRect(x: $0 - 40, y: 594, width: 80, height: 44) }

    static func field(stop: Int? = nil, keyboard: Bool = false) -> MascotField {
        var field = MascotField(visible: visible, pane: stop == nil ? pane : openPane, well: well)
        field.stop = stop.map { stops[$0] }
        if keyboard { field.keyboard = CGRect(x: 0, y: 720, width: 402, height: 400) }
        return field
    }

    static func settings(_ placement: Look.Mascot.Placement = .roam) -> MascotRoam.Settings {
        MascotRoam.Settings(size: size, clearance: 8, reach: reach, speed: 40, hurry: 10, settle: 0.6, placement: placement)
    }

    private func run(_ roam: inout MascotRoam, time: inout Double, for seconds: Double = 60) {
        let until = time + seconds
        repeat {
            time += Self.frame
            roam.advance(to: time)
        } while roam.needsTime && time < until
    }

    /// What the layer does with each geometry: the settings the slider makes of the look's, then
    /// the geometry.
    private func hand(_ roam: inout MascotRoam, _ field: MascotField, _ placement: Look.Mascot.Placement = .roam,
                      at time: Double) {
        roam.use(MascotPerch.sliding(Self.settings(placement), over: field, swim: 240))
        roam.observe(field, at: time)
    }

    // MARK: The line

    func testAFingerOnTheLineIsAtTheStopItIsNearest() {
        let nearest = { Composer.Models.nearest(to: $0, width: 321, inset: 40, count: 3) }
        XCTAssertEqual(nearest(-50), 0)
        XCTAssertEqual(nearest(40), 0)
        XCTAssertEqual(nearest(99), 0)
        XCTAssertEqual(nearest(101), 1)
        XCTAssertEqual(nearest(160.5), 1)
        XCTAssertEqual(nearest(222), 2)
        XCTAssertEqual(nearest(4_000), 2)
        XCTAssertNil(nearest(.nan))
        XCTAssertNil(Composer.Models.nearest(to: 10, width: 321, inset: 40, count: 0))
        XCTAssertEqual(Composer.Models.nearest(to: 10, width: 321, inset: 40, count: 1), 0)
        // A pane narrower than its two insets still answers a stop.
        XCTAssertEqual(Composer.Models.nearest(to: 30, width: 40, inset: 40, count: 3), 0)
        XCTAssertEqual([0, 1, 2].map { Composer.Models.share(of: $0, count: 3) }, [0, 0.5, 1])
        XCTAssertEqual(Composer.Models.share(of: 0, count: 1), 0.5)
    }

    // MARK: Where he sits

    /// Over each stop his body's axis is over the stop's middle and the engine's shelf is on the
    /// pane's top edge; with no stop or no pane there is no such place and the look's settings
    /// stand.
    func testHeSitsOnThePanesTopEdgeOverTheChosenStop() throws {
        for index in 0..<3 {
            let field = Self.field(stop: index)
            let box = try XCTUnwrap(MascotPerch.over(field, size: Self.size))
            XCTAssertEqual(box.midX, Self.stops[index].midX, accuracy: 1e-9)
            XCTAssertEqual(box.minY + CGFloat(Topo.shelfY) - MascotSprite.box.minY, Self.openPane.minY, accuracy: 1e-9)
            XCTAssertEqual(box.size, Self.size)
            let sliding = MascotPerch.sliding(Self.settings(.glass), over: field, swim: 240)
            XCTAssertEqual(sliding.placement, .pinned)
            XCTAssertEqual(sliding.speed, 240)
            // The pin puts him back where the box is, his reach inside the frame at every stop.
            let placed = try XCTUnwrap(MascotPerch.pinned(sliding.pin, in: field.pinFrame, keyboard: nil, size: Self.size,
                                                          reach: Self.reach, clearance: 8))
            XCTAssertEqual(placed.midX, box.midX, accuracy: 1e-6, "stop \(index)")
            XCTAssertEqual(placed.minY, box.minY, accuracy: 1e-6, "stop \(index)")
        }
        XCTAssertNil(MascotPerch.over(Self.field(), size: Self.size))
        var paneless = Self.field(stop: 1)
        paneless.pane = nil
        XCTAssertNil(MascotPerch.over(paneless, size: Self.size))
        for placement in Look.Mascot.Placement.allCases {
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), over: Self.field(), swim: 240), Self.settings(placement))
            XCTAssertEqual(MascotPerch.sliding(Self.settings(placement), over: nil, swim: 240), Self.settings(placement))
        }
    }

    // MARK: Going there

    /// The slider opening is one glide from where he stands to the chosen stop, at the swim; a new
    /// stop is one more, along the pane's top edge; and the slider shutting is a glide from the
    /// glass back to where his own placement has him, never a jump.
    func testHeGlidesToTheSliderAlongItAndAway() throws {
        for placement in Look.Mascot.Placement.allCases {
            var time = 0.0
            var roam = MascotRoam(Self.settings(placement), frame: Self.frame)
            hand(&roam, Self.field(), placement, at: time)
            run(&roam, time: &time)
            let home = try XCTUnwrap(roam.position, "\(placement): never placed")

            // Open, on the first stop.
            var moves = roam.moves
            hand(&roam, Self.field(stop: 0), placement, at: time)
            let there = try XCTUnwrap(roam.move, "\(placement): put on the slider rather than glided")
            XCTAssertEqual(there.from, home, "\(placement)")
            XCTAssertEqual(there.duration, Double(hypot(there.to.x - home.x, there.to.y - home.y) / 240), accuracy: 1e-9,
                           "\(placement): not at the swim")
            XCTAssertEqual(roam.moves, moves + 1, "\(placement)")
            run(&roam, time: &time)
            let first = try XCTUnwrap(MascotPerch.over(Self.field(stop: 0), size: Self.size))
            XCTAssertEqual(try XCTUnwrap(roam.picture).midX, first.midX, accuracy: 1e-6, "\(placement)")
            XCTAssertEqual(try XCTUnwrap(roam.picture).minY, first.minY, accuracy: 1e-6, "\(placement)")

            // The last stop: one glide along the edge.
            moves = roam.moves
            hand(&roam, Self.field(stop: 2), placement, at: time)
            let along = try XCTUnwrap(roam.move, "\(placement): put at the new stop rather than glided")
            XCTAssertEqual(along.from.y, along.to.y, accuracy: 1e-6, "\(placement): left the pane's edge on the way")
            XCTAssertEqual(roam.moves, moves + 1, "\(placement)")
            run(&roam, time: &time)
            let last = try XCTUnwrap(MascotPerch.over(Self.field(stop: 2), size: Self.size))
            XCTAssertEqual(try XCTUnwrap(roam.picture).midX, last.midX, accuracy: 1e-6, "\(placement)")

            // Shut: back to his own placement, by a glide that starts where he sat.
            let sat = try XCTUnwrap(roam.position)
            hand(&roam, Self.field(), placement, at: time)
            let back = try XCTUnwrap(roam.move, "\(placement): jumped off the slider")
            XCTAssertEqual(back.from, sat, "\(placement)")
            if placement != .roam {
                // A placed Topo goes home as he came, at the swim: six times these settings' stroll.
                XCTAssertEqual(back.pace, 240 / 40, accuracy: 1e-9, "\(placement): strolled home across the glass")
            }
            XCTAssertEqual(roam.position, sat, "\(placement): moved before the glide")
            time += Self.frame
            roam.advance(to: time)
            let step = try XCTUnwrap(roam.position)
            XCTAssertLessThan(hypot(step.x - sat.x, step.y - sat.y), 40, "\(placement): a jump, not a glide")
            run(&roam, time: &time)
            XCTAssertNil(roam.move, "\(placement)")
            XCTAssertFalse(roam.leaving, "\(placement)")
            let ended = try XCTUnwrap(roam.picture)
            if placement == .roam {
                // Roaming, a roost is decided from where he stands: the nearest gap, off the glass.
                // Where he sat hangs below the transcript's foot, so inside it is somewhere else.
                XCTAssertEqual(roam.roost.name, "gap")
                XCTAssertFalse(Self.visible.contains(CGRect(origin: sat, size: Self.size)))
                XCTAssertTrue(Self.visible.contains(ended), "roaming, left on the glass: \(ended)")
            } else {
                XCTAssertEqual(ended.origin.x, home.x, accuracy: 1, "\(placement): not back where his placement has him")
                XCTAssertEqual(ended.origin.y, home.y, accuracy: 1, "\(placement): not back where his placement has him")
            }
        }
    }

    /// The keyboard rising while he is on his way off the glass still places him: the glass comes
    /// up under that glide, and he is not drawn crossing it.
    func testTheKeyboardRisingUnderTheGlideAwayStillPlacesHim() throws {
        var time = 0.0
        var roam = MascotRoam(Self.settings(), frame: Self.frame)
        hand(&roam, Self.field(), at: time)
        run(&roam, time: &time)
        hand(&roam, Self.field(stop: 1), at: time)
        run(&roam, time: &time)
        hand(&roam, Self.field(), at: time)
        XCTAssertTrue(roam.leaving)
        let risen = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 330),
                                pane: CGRect(x: 40, y: 344, width: 321, height: 53),
                                well: CGRect(x: 177, y: 346, width: 48, height: 48),
                                keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
        roam.observe(risen, at: time)
        let placed = try XCTUnwrap(roam.picture)
        XCTAssertLessThanOrEqual(Self.reach.around(placed).maxY, risen.pane!.minY + MascotRoost.epsilon,
                                 "left under the glass the keyboard brought up")
    }

    /// On the glass, the keyboard rising as the slider shuts places him on the short pane at
    /// once: a glide there would cross the well and end under the keyboard's top edge on its way.
    func testOnTheGlassTheKeyboardRisingAsTheSliderShutsPlacesHim() throws {
        var time = 0.0
        var roam = MascotRoam(Self.settings(.glass), frame: Self.frame)
        hand(&roam, Self.field(), .glass, at: time)
        run(&roam, time: &time)
        for stop in 0..<3 {
            hand(&roam, Self.field(stop: stop), .glass, at: time)
            run(&roam, time: &time)
            // Shut, and gliding home; then the keyboard.
            hand(&roam, Self.field(), .glass, at: time)
            XCTAssertNotNil(roam.move, "stop \(stop)")
            time += Self.frame
            roam.advance(to: time)
            let risen = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 330),
                                    pane: CGRect(x: 40, y: 344, width: 321, height: 53),
                                    well: CGRect(x: 177, y: 346, width: 48, height: 48),
                                    keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
            hand(&roam, risen, .glass, at: time)
            let home = try XCTUnwrap(MascotPerch.glass(risen, size: Self.size))
            XCTAssertNil(roam.move, "stop \(stop): still gliding with the keyboard up")
            XCTAssertEqual(roam.position, home.origin, "stop \(stop): not on the short glass")
            hand(&roam, Self.field(), .glass, at: time)
            run(&roam, time: &time)
        }
    }

    /// The slider open over the keyboard: he sits over the chosen stop on the short pane, whatever
    /// his placement, not lifted clear of the keyboard as a pin of the person's is; a new stop is a
    /// glide along it; and the keyboard going under the open slider takes him down with the pane.
    func testOverTheKeyboardHeSitsOverTheStopOnTheShortPane() throws {
        let short = CGRect(x: 40, y: 298, width: 321, height: 99)
        let risen = { (stop: Int?) -> MascotField in
            var field = MascotField(visible: CGRect(x: 0, y: 0, width: 402, height: 330),
                                    pane: stop == nil ? CGRect(x: 40, y: 344, width: 321, height: 53) : short,
                                    well: CGRect(x: 177, y: 346, width: 48, height: 48),
                                    keyboard: CGRect(x: 0, y: 400, width: 402, height: 474))
            field.stop = stop.map { CGRect(x: Self.stops[$0].minX, y: short.minY + 8, width: 80, height: 44) }
            return field
        }
        for placement in Look.Mascot.Placement.allCases {
            var time = 0.0
            var roam = MascotRoam(Self.settings(placement), frame: Self.frame)
            hand(&roam, Self.field(), placement, at: time)
            run(&roam, time: &time)
            hand(&roam, risen(nil), placement, at: time)
            run(&roam, time: &time)
            for stop in [0, 2] {
                hand(&roam, risen(stop), placement, at: time)
                run(&roam, time: &time)
                let sat = try XCTUnwrap(roam.picture, "\(placement): nowhere over the keyboard")
                XCTAssertEqual(sat.midX, Self.stops[stop].midX, accuracy: 1e-6, "\(placement), stop \(stop)")
                XCTAssertEqual(sat.minY + CGFloat(Topo.shelfY) - MascotSprite.box.minY, short.minY, accuracy: 1e-6,
                               "\(placement), stop \(stop): not on the short pane's top edge")
            }
            // The keyboard goes with the slider still open: he is over the stop on the resting pane.
            hand(&roam, Self.field(stop: 2), placement, at: time)
            run(&roam, time: &time)
            let down = try XCTUnwrap(MascotPerch.over(Self.field(stop: 2), size: Self.size))
            XCTAssertEqual(try XCTUnwrap(roam.picture).origin.y, down.minY, accuracy: 1e-6, "\(placement): left where the keyboard had him")
        }
    }

    /// Over the slider he is not to be picked up: a press there is the slider's, and a drop would
    /// pin him where the slider had put him. Once it is shut and he is home he is again.
    func testHeIsNotGrabbedOverTheSlider() throws {
        var time = 0.0
        var roam = MascotRoam(Self.settings(), frame: Self.frame)
        hand(&roam, Self.field(), at: time)
        run(&roam, time: &time)
        hand(&roam, Self.field(stop: 1), at: time)
        run(&roam, time: &time)
        let sat = try XCTUnwrap(roam.picture)
        let knob = CGPoint(x: Self.stops[1].midX, y: Self.stops[1].minY + 9)
        XCTAssertTrue(sat.contains(knob), "the knob is not under him, so this holds nothing")
        XCTAssertFalse(roam.grabbable(at: knob))
        XCTAssertFalse(roam.grabbable(at: CGPoint(x: sat.midX, y: sat.midY)))
        hand(&roam, Self.field(), at: time)
        run(&roam, time: &time)
        let home = try XCTUnwrap(roam.picture)
        XCTAssertTrue(roam.grabbable(at: CGPoint(x: home.midX, y: home.midY)))
    }

    // MARK: Names

    /// What the slider and the notice call a model is the look's name for it, and the family's
    /// where the look names none; a document sets one name without touching the others, and one
    /// it refuses costs that name alone.
    func testAModelIsCalledWhatTheLookCallsIt() {
        XCTAssertEqual(ClaudeModel.allCases.map { Look.Mind().name($0.rawValue) }, ClaudeModel.allCases.map(\.displayName))
        XCTAssertNil(Look.Mind().name(ClaudeModel.haiku.rawValue))
        let reading = LookDocument.read(#"{"mind": {"sonnet": "  Sonnet 5.5 ", "opus": "", "fable": 7}}"#)
        XCTAssertEqual(reading.look.mind.sonnet, "Sonnet 5.5")
        XCTAssertEqual(reading.look.mind.opus, "Opus")
        XCTAssertEqual(reading.look.mind.fable, "Fable")
        XCTAssertEqual(reading.notes.count, 2, "\(reading.notes)")
        for refused in [String(repeating: "m", count: Look.Mind.longest + 1), "two\nlines", "   "] {
            let data = try! JSONSerialization.data(withJSONObject: ["mind": ["opus": refused]])
            let read = LookDocument.read(String(data: data, encoding: .utf8))
            XCTAssertEqual(read.look.mind.opus, "Opus", refused.debugDescription)
            XCTAssertEqual(read.notes.count, 1, refused.debugDescription)
        }
    }

    // MARK: Mute

    /// Read aloud until somebody mutes: a phone never asked reads replies.
    func testRepliesAreReadAloudUntilMuted() throws {
        let name = "mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(Mute.readsAloud(defaults))
        defaults.set(false, forKey: Mute.key)
        XCTAssertFalse(Mute.readsAloud(defaults))
        defaults.set(true, forKey: Mute.key)
        XCTAssertTrue(Mute.readsAloud(defaults))
    }

    // MARK: Drawn

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let view = view as? T { return view }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// The chat hosted with the slider open on each stop: he stands pinned over the stop chosen,
    /// his body's axis over its middle and his shelf on the pane's top edge, wearing the head of
    /// the model chosen. The picture of each is attached.
    func testInTheChatHeIsDrawnOverTheChosenStopWearingItsHead() throws {
        var look = Look()
        look.composer.surface = .flat
        let stops = ClaudeModel.allCases.map { Composer.Models.Stop(id: $0.rawValue, name: $0.displayName) }
        var levels: [Double] = []
        for model in ClaudeModel.allCases {
            // As the chat hands him over (`Mascot.drawn`): a debug build's Haiku, mid-turn, wearing
            // the slider's choice.
            let mascot = Mascot(model: ClaudeModel.haiku.rawValue)
            mascot.chosen = model.rawValue
            mascot.guestTurnBegan()
            mascot.guest(.event(.started(session: "s", model: ClaudeModel.haiku.rawValue)))
            let view = ChatCanvas(turns: PreviewTurns.long, mascot: mascot.drawn,
                                  models: Composer.Models(stops: stops, chosen: model.rawValue, open: true))
                .environment(\.look, look)
                .environment(\.scenePhase, .active)
                .transaction { $0.animation = nil }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            defer { window.isHidden = true }
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            window.layoutIfNeeded()
            let canvas = try XCTUnwrap(find(MascotCanvas.self, in: window), "no Topo over the chat")
            for _ in 0..<90 { canvas.step(1.0 / 30) }
            let roam = try XCTUnwrap(canvas.roam)
            let field = try XCTUnwrap(roam.field)
            let stop = try XCTUnwrap(field.stop, "\(model): the chosen stop reported nothing")
            let pane = try XCTUnwrap(field.pane)
            let box = try XCTUnwrap(roam.picture, "\(model): he stands nowhere")
            XCTAssertEqual(roam.roost.name, "pinned", "\(model)")
            XCTAssertEqual(box.midX, stop.midX, accuracy: 1, "\(model): not over the chosen stop")
            XCTAssertEqual(box.minY + (CGFloat(Topo.shelfY) - MascotSprite.box.minY) * look.mascot.scale, pane.minY, accuracy: 1,
                           "\(model): his shelf is not on the pane's top edge")
            XCTAssertTrue(pane.contains(stop), "\(model): the stop is not on the pane")
            // The head the engine was handed, off the canvas that drew him.
            XCTAssertEqual(canvas.driver.headInForce, levelForModel(model.rawValue), "\(model): not the chosen model's head")
            levels.append(canvas.driver.headInForce)
            CATransaction.flush()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "model-slider-\(model.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["TOPO_TEST_PICTURES"] {
                try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("model-slider-\(model.rawValue).png"))
            }
        }
        // Smallest to largest along the slider, and none the brain.
        XCTAssertEqual(levels, [1, 2, 3])
    }
}
