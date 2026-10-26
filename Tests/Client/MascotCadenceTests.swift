import CoreGraphics
import TopoMascot
import UIKit
import XCTest

@testable import Topo

/// His frames come at the look's rate while he does anything and at the rest's once he has
/// rested: a turn, a glide or a finger on him brings the look's rate back at once, and a rest
/// goes on across his being hidden, since the clock it is measured on stops with the link.
@MainActor
final class MascotCadenceTests: XCTestCase {
    private let seen = MascotDriver.Conditions(active: true, onScreen: true, opacity: 1, covered: false,
                                               reduceMotion: false)
    private let look = Look.Mascot()

    /// A canvas in a window over the empty chat, told `state`, moved on `seconds`.
    private func canvas() -> MascotCanvas {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let canvas = MascotCanvas(frame: window.bounds)
        window.addSubview(canvas)
        objc_setAssociatedObject(canvas, &Self.windowKey, window, .OBJC_ASSOCIATION_RETAIN)
        return canvas
    }
    private static var windowKey = 0

    private func tell(_ canvas: MascotCanvas, _ state: MascotState, conditions: MascotDriver.Conditions? = nil) {
        canvas.apply(input: state.input, field: MascotPlacementTests.field(),
                     settings: MascotPlacementTests.settings(.roam), interval: look.frameInterval,
                     restInterval: look.restInterval, restAfter: look.restAfter, conditions: conditions ?? seen)
    }

    private func run(_ canvas: MascotCanvas, seconds: Double) {
        for _ in 0..<Int((seconds / look.frameInterval).rounded(.up)) { canvas.step(look.frameInterval) }
    }

    func testHeRestsToTheRestsRateAndAnythingHeDoesBringsTheLooksBack() {
        let canvas = canvas()
        let idle = MascotState(model: "claude-sonnet-5")
        tell(canvas, idle)
        // The first place is a glide from nowhere, then the settle: he is not resting yet.
        run(canvas, seconds: 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a Topo still arriving is at the look's rate")
        run(canvas, seconds: look.restAfter + 2)
        XCTAssertEqual(canvas.cadence, look.restInterval, "rested, his frames come at the rest's rate")

        // A turn opening is the thinking pose: the look's rate on the frame it is seen.
        var open = idle
        open.turnOpen = true
        tell(canvas, open)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a turn in flight is not rest")
        run(canvas, seconds: look.restAfter + 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "the turn is still open")

        // The turn ends: the rest starts afresh and takes its time again.
        tell(canvas, idle)
        XCTAssertEqual(canvas.cadence, look.frameInterval)
        run(canvas, seconds: look.restAfter / 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "half a rest is not one")
        run(canvas, seconds: look.restAfter / 2 + 1)
        XCTAssertEqual(canvas.cadence, look.restInterval)
    }

    func testAGlideAndAFingerAreNotRestAndARestGoesOnWhileHeIsHidden() throws {
        let canvas = canvas()
        let idle = MascotState(model: "claude-sonnet-5")
        tell(canvas, idle)
        run(canvas, seconds: look.restAfter + 4)
        XCTAssertEqual(canvas.cadence, look.restInterval)

        // A finger on him.
        let box = canvas.spriteFrame
        XCTAssertNotNil(canvas.drag(from: CGPoint(x: box.minX + 4, y: box.minY + 4), to: CGPoint(x: 200, y: 300)))
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a press on him is not rest")
        run(canvas, seconds: look.restAfter + 4)
        XCTAssertEqual(canvas.cadence, look.restInterval, "let go, he rests again")

        // Hidden — the chat covered — the clock stops with the link; back in front he is still rested.
        var covered = seen
        covered.covered = true
        tell(canvas, idle, conditions: covered)
        tell(canvas, idle)
        XCTAssertEqual(canvas.cadence, look.restInterval, "coming back finds him rested")

        // A new place is a glide, which is the walk: the look's rate while it lasts.
        let fresh = self.canvas()
        tell(fresh, idle)
        run(fresh, seconds: look.restAfter + 4)
        XCTAssertEqual(fresh.cadence, look.restInterval)
        fresh.apply(input: idle.input, field: MascotPlacementTests.field(),
                    settings: MascotPlacementTests.settings(.glass), interval: look.frameInterval,
                    restInterval: look.restInterval, restAfter: look.restAfter, conditions: seen)
        var glided = false
        for _ in 0..<Int(3 / look.frameInterval) {
            fresh.step(look.frameInterval)
            if fresh.roam?.walking == true {
                glided = true
                XCTAssertEqual(fresh.cadence, look.frameInterval, "a glide is not rest")
                break
            }
        }
        XCTAssertTrue(glided, "the new place did not move him within three seconds")
    }
}
