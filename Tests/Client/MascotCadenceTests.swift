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

    /// A window on the test host's scene for a canvas to be in, so its link exists and asks the
    /// display for a rate.
    private func stageWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.isHidden = false
        return window
    }

    private func canvas(in window: UIWindow) -> MascotCanvas {
        let canvas = MascotCanvas(frame: window.bounds)
        window.addSubview(canvas)
        return canvas
    }

    /// The canvas told `state` over the empty chat, with the look's rates.
    private func tell(_ canvas: MascotCanvas, _ state: MascotState, conditions: MascotDriver.Conditions? = nil) {
        canvas.apply(input: state.input, field: MascotPlacementTests.field(),
                     settings: MascotPlacementTests.settings(.roam), interval: look.frameInterval,
                     restInterval: look.restInterval, restAfter: look.restAfter, conditions: conditions ?? seen)
    }

    /// The canvas moved on `seconds` at the look's rate.
    private func run(_ canvas: MascotCanvas, seconds: Double) {
        for _ in 0..<Int((seconds / look.frameInterval).rounded(.up)) { canvas.step(look.frameInterval) }
    }

    /// What a frame lasts now, and what the link asks the display for, which is the saving.
    private func rate(_ canvas: MascotCanvas) -> (cadence: Double, link: Float?) { (canvas.cadence, canvas.frameRate) }

    func testHeRestsToTheRestsRateAndAnythingHeDoesBringsTheLooksBack() throws {
        let window = try stageWindow()
        defer { window.isHidden = true }
        let canvas = canvas(in: window)
        let idle = MascotState(model: "claude-sonnet-5")
        tell(canvas, idle)
        // Placed from nowhere at once, he rests from the first frame; two seconds in he is not
        // rested yet.
        run(canvas, seconds: 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a Topo two seconds idle is at the look's rate")
        XCTAssertEqual(canvas.frameRate, 24)
        run(canvas, seconds: look.restAfter + 2)
        XCTAssertEqual(canvas.cadence, look.restInterval, "rested, his frames come at the rest's rate")
        XCTAssertEqual(canvas.frameRate, 12, "the rest's rate did not reach the link")

        // A turn opening is the thinking pose: the look's rate on the frame it is seen.
        var open = idle
        open.turnOpen = true
        tell(canvas, open)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a turn in flight is not rest")
        XCTAssertEqual(canvas.frameRate, 24)
        run(canvas, seconds: look.restAfter + 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "the turn is still open")

        // The turn ends: the rest starts afresh and takes its time again.
        tell(canvas, idle)
        XCTAssertEqual(canvas.cadence, look.frameInterval)
        run(canvas, seconds: look.restAfter / 2)
        XCTAssertEqual(canvas.cadence, look.frameInterval, "half a rest is not one")
        run(canvas, seconds: look.restAfter / 2 + 1)
        XCTAssertEqual(canvas.cadence, look.restInterval)
        XCTAssertEqual(canvas.frameRate, 12)

        // A rested Topo's stalled callback moves the clock on by two of his frames and no more.
        let before = canvas.clock
        canvas.fire(at: 1_000)
        canvas.fire(at: 1_060)
        XCTAssertEqual(canvas.clock - before, look.restInterval + MascotCanvas.stepCap(interval: look.restInterval),
                       accuracy: 0.0001, "a stall at rest moved him by other than the rest's cap")
    }

    func testAGlideAndAFingerAreNotRestAndARestGoesOnWhileHeIsHidden() throws {
        let window = try stageWindow()
        defer { window.isHidden = true }
        let canvas = canvas(in: window)
        let idle = MascotState(model: "claude-sonnet-5")
        tell(canvas, idle)
        run(canvas, seconds: look.restAfter + 4)
        XCTAssertEqual(canvas.cadence, look.restInterval)
        XCTAssertEqual(canvas.frameRate, 12)

        // A finger on him.
        let box = canvas.spriteFrame
        XCTAssertNotNil(canvas.drag(from: CGPoint(x: box.minX + 4, y: box.minY + 4), to: CGPoint(x: 200, y: 300)))
        XCTAssertEqual(canvas.cadence, look.frameInterval, "a press on him is not rest")
        XCTAssertEqual(canvas.frameRate, 24)
        run(canvas, seconds: look.restAfter + 4)
        XCTAssertEqual(canvas.cadence, look.restInterval, "let go, he rests again")

        // Hidden — the chat covered — the clock stops with the link; back in front he is still rested.
        var covered = seen
        covered.covered = true
        tell(canvas, idle, conditions: covered)
        tell(canvas, idle)
        XCTAssertEqual(canvas.cadence, look.restInterval, "coming back finds him rested")

        // A new place is a glide, which is the walk: the look's rate while it lasts.
        let fresh = self.canvas(in: window)
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
                XCTAssertEqual(fresh.frameRate, 24)
                break
            }
        }
        XCTAssertTrue(glided, "the new place did not move him within three seconds")
    }
}
