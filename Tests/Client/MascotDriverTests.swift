import SwiftUI
import TopoMascot
import UIKit
import XCTest

@testable import Topo

/// Topo costs nothing he does not need: frames are drawn only while he is seen and may move,
/// under Reduce Motion he is one still of his idle pose per state, and the display link that
/// asks for frames runs exactly while frames are wanted.
@MainActor
final class MascotDriverTests: XCTestCase {
    private let seen = MascotDriver.Conditions(active: true, onScreen: true, opacity: 1, covered: false,
                                               reduceMotion: false)

    private func driver(_ conditions: MascotDriver.Conditions) -> MascotDriver {
        let driver = MascotDriver()
        driver.input = MascotState(model: "claude-sonnet-5", tokens: 1_000, activity: .building).input
        driver.conditions = conditions
        return driver
    }

    func testFramesAreDrawnWhileHeIsSeen() {
        let driver = driver(seen)
        for _ in 0..<5 { driver.tick(1.0 / 30) }
        XCTAssertEqual(driver.frames, 5)
        XCTAssertNotNil(driver.image)
    }

    /// His flank faded part of the way by the microphone's hold is still him seen, so frames go
    /// on; faded to nothing, they stop.
    func testAPartlyFadedFlankKeepsHisFramesAndANoneStopsThem() {
        for (opacity, drawn) in [(0.5, true), (0.01, true), (0, false)] as [(Double, Bool)] {
            var conditions = seen
            conditions.opacity = opacity
            let driver = driver(conditions)
            for _ in 0..<5 { driver.tick(1.0 / 30) }
            XCTAssertEqual(driver.frames, drawn ? 5 : 0, "at \(opacity)")
        }
    }

    /// Inactive or backgrounded, out of the window, his flank faded to nothing by the microphone's hold,
    /// or a sheet over him: each alone stops every frame.
    func testNoFramesWhileUnseen() {
        var inactive = seen; inactive.active = false
        var offScreen = seen; offScreen.onScreen = false
        var faded = seen; faded.opacity = 0
        var covered = seen; covered.covered = true
        for (why, conditions) in [("inactive", inactive), ("off screen", offScreen), ("faded", faded),
                                  ("covered", covered)] {
            let driver = driver(conditions)
            for _ in 0..<10 { driver.tick(1.0 / 30) }
            XCTAssertEqual(driver.frames, 0, why)
            XCTAssertNil(driver.image, why)
            XCTAssertFalse(conditions.animates, why)
        }
    }

    /// Under Reduce Motion no tick draws. What is drawn is one still of the idle pose, once per
    /// head and load band; a change of pose draws nothing, since he is held in his idle one.
    func testReduceMotionIsOneStillPerStateAndNoFrames() throws {
        var still = seen; still.reduceMotion = true
        let driver = driver(still)
        XCTAssertEqual(driver.frames, 1, "the still is drawn as he is seen")
        let first = try XCTUnwrap(driver.image)
        for _ in 0..<30 { driver.tick(1.0 / 30) }
        XCTAssertEqual(driver.frames, 1, "a tick drew under Reduce Motion")

        driver.input = MascotState(model: "claude-sonnet-5", tokens: 1_000, activity: .searching).input
        XCTAssertEqual(driver.frames, 1, "a new pose drew a still, which is only ever idle")
        driver.input = MascotState(model: "claude-sonnet-5", tokens: 1_000, activity: .searching).input
        XCTAssertEqual(driver.frames, 1)

        driver.input = MascotState(model: "claude-fable-5-1", tokens: 260_000, activity: .searching).input
        XCTAssertEqual(driver.frames, 2, "a new head and load is a new still")
        XCTAssertNotEqual(bytes(first), bytes(try XCTUnwrap(driver.image)))

        // Unseen under Reduce Motion is nothing at all.
        var hidden = still; hidden.active = false
        driver.conditions = hidden
        driver.input = MascotState(model: "claude-haiku-4-5", tokens: 1, activity: .idle).input
        XCTAssertEqual(driver.frames, 2)
    }

    /// The still is drawn again only for what the engine draws differently: the head the model
    /// picks and the band the tokens fall in. Tokens moving within a band, or another id of the
    /// same model, is the same picture and draws nothing; crossing into the next band draws one.
    func testReduceMotionDrawsANewStillOnlyForANewHeadOrLoadBand() throws {
        var still = seen; still.reduceMotion = true
        let driver = driver(still)
        XCTAssertEqual(driver.frames, 1)
        let first = try XCTUnwrap(driver.image)

        driver.input = MascotState(model: "claude-sonnet-5", tokens: 1_001).input
        XCTAssertEqual(driver.frames, 1, "a token more in the same load drew another still")
        driver.input = MascotState(model: "claude-sonnet-5", tokens: 199_999).input
        XCTAssertEqual(driver.frames, 1, "tokens within the default load drew another still")
        driver.input = MascotState(model: "claude-sonnet-5-20260801", tokens: 199_999).input
        XCTAssertEqual(driver.frames, 1, "another id of the same model drew another still")

        driver.input = MascotState(model: "claude-sonnet-5", tokens: 200_000).input
        XCTAssertEqual(driver.frames, 2, "the warning load drew no still")
        driver.input = MascotState(model: "claude-opus-5", tokens: 200_000).input
        XCTAssertEqual(driver.frames, 3, "a new head drew no still")
        XCTAssertNotEqual(bytes(first), bytes(try XCTUnwrap(driver.image)))
    }

    /// The still is the idle pose whatever the state's pose is: the same picture for building as
    /// for idle.
    func testTheStillIsTheIdlePose() throws {
        var still = seen; still.reduceMotion = true
        let building = driver(still)
        let idle = MascotDriver()
        idle.input = MascotState(model: "claude-sonnet-5", tokens: 1_000, activity: .idle).input
        idle.conditions = still
        XCTAssertEqual(bytes(try XCTUnwrap(building.image)), bytes(try XCTUnwrap(idle.image)))
    }

    // MARK: The clock

    /// The canvas's display link runs while he animates, at the look's rate, and is gone the
    /// moment any condition says he is unseen or held still.
    func testTheLinkRunsExactlyWhileHeAnimates() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let placement = MascotPlacement(frame: canvas.frame, home: CGPoint(x: 50, y: 90), scale: 1, corner: -20)
        let input = MascotState(model: "claude-sonnet-5").input
        func apply(_ conditions: MascotDriver.Conditions, interval: Double = 1.0 / 30) {
            canvas.apply(input: input, placement: placement, interval: interval, conditions: conditions)
        }

        apply(seen)
        XCTAssertFalse(canvas.isTicking, "a canvas in no window asked for frames")

        let window = try XCTUnwrap(stageWindow())
        defer { window.isHidden = true }
        window.addSubview(canvas)
        apply(seen)
        XCTAssertTrue(canvas.isTicking)
        XCTAssertEqual(canvas.frameRate, 30)
        apply(seen, interval: 0.1)
        XCTAssertEqual(canvas.frameRate, 10, "the look's frame interval does not reach the clock")

        var inactive = seen; inactive.active = false
        var faded = seen; faded.opacity = 0
        var covered = seen; covered.covered = true
        var still = seen; still.reduceMotion = true
        for conditions in [inactive, faded, covered, still] {
            apply(conditions)
            XCTAssertFalse(canvas.isTicking, "\(conditions)")
            apply(seen)
            XCTAssertTrue(canvas.isTicking)
        }

        canvas.removeFromSuperview()
        XCTAssertFalse(canvas.isTicking, "a canvas taken out of the window kept asking for frames")
    }

    /// Over an empty transcript he floats: half a period into the bob he is the look's amplitude
    /// up off where he would stand, and on the glass whole, or under Reduce Motion, he is not up
    /// at all.
    func testHeBobsOverNoPaneAndNotOnTheGlassOrUnderReduceMotion() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        let placement = MascotPlacement(frame: canvas.frame, home: CGPoint(x: 50, y: 150), scale: 1, corner: 0)
        let input = MascotState(model: "claude-sonnet-5").input
        let window = try XCTUnwrap(stageWindow())
        defer { window.isHidden = true }
        window.addSubview(canvas)
        var mascot = Look.Mascot()
        mascot.bobAmplitude = 10
        mascot.bobPeriod = 2
        let resting = placement.sprite(x: 0).minY

        canvas.apply(input: input, placement: placement, interval: 1.0 / 30,
                     hover: MascotHover(mascot, presence: 0), conditions: seen)
        canvas.step(1)
        XCTAssertEqual(canvas.lift, 10, accuracy: 1e-9, "half a period over no pane is the whole bob")
        XCTAssertEqual(canvas.spriteFrame.minY, resting - 10, accuracy: 1e-6, "the lift is not where he is drawn")

        canvas.apply(input: input, placement: placement, interval: 1.0 / 30,
                     hover: MascotHover(mascot, presence: 1), conditions: seen)
        XCTAssertEqual(canvas.lift, 0, "on the glass whole he still bobs")
        XCTAssertEqual(canvas.spriteFrame.minY, resting, accuracy: 1e-6)

        var still = seen
        still.reduceMotion = true
        canvas.apply(input: input, placement: placement, interval: 1.0 / 30,
                     hover: MascotHover(mascot, presence: 0), conditions: still)
        XCTAssertEqual(canvas.lift, 0, "he bobs under Reduce Motion")
        XCTAssertEqual(canvas.spriteFrame.minY, resting, accuracy: 1e-6)
        XCTAssertFalse(canvas.isTicking, "Reduce Motion asked for frames to bob him with")
    }

    /// He takes no touch and is nothing to accessibility.
    func testTheCanvasTakesNoTouchAndIsHidden() {
        let canvas = MascotCanvas(frame: .zero)
        XCTAssertFalse(canvas.isUserInteractionEnabled)
        XCTAssertFalse(canvas.isAccessibilityElement)
        XCTAssertTrue(canvas.accessibilityElementsHidden)
        XCTAssertTrue(canvas.clipsToBounds)
    }

    private func stageWindow() -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.isHidden = false
        return window
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
