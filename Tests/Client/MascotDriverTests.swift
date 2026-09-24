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

    /// Faded part of the way by the microphone's hold, with the glass's flanks, is still him seen, so frames go
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

    /// Inactive or backgrounded, out of the window, faded to nothing by the microphone's hold,
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

    /// A chat with room in it: an empty transcript over a pane.
    static let open = MascotField(visible: CGRect(x: 0, y: 0, width: 400, height: 600),
                                  pane: CGRect(x: 40, y: 600, width: 320, height: 80),
                                  well: CGRect(x: 164, y: 604, width: 72, height: 72))
    static let settings = MascotRoam.Settings(size: MascotSprite.size(scale: 2.0 / 3), clearance: 8, speed: 40,
                                              settle: 0.6)

    /// The canvas's display link runs while he animates, at the look's rate, and is gone the
    /// moment any condition says he is unseen or held still, once nothing of his roam waits on
    /// the clock.
    func testTheLinkRunsExactlyWhileHeAnimates() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let input = MascotState(model: "claude-sonnet-5").input
        func apply(_ conditions: MascotDriver.Conditions, interval: Double = 1.0 / 30) {
            canvas.apply(input: input, field: Self.open, settings: Self.settings, interval: interval,
                         conditions: conditions)
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
        // The first geometry is a decision still owed its settle; let it settle.
        for _ in 0..<30 { canvas.step(0.1) }
        XCTAssertEqual(canvas.roam?.needsTime, false)

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

    /// Standing nowhere is not animating: no frame is drawn for a Topo with nowhere to stand, and
    /// once his roam has nothing waiting on the clock the link stops, so he costs nothing.
    func testATopoStandingNowhereDrawsNoFrameAndStopsTheLink() throws {
        var nowhere = seen
        nowhere.hidden = true
        let driver = driver(nowhere)
        for _ in 0..<10 { driver.tick(1.0 / 30) }
        XCTAssertEqual(driver.frames, 0)
        XCTAssertFalse(nowhere.animates)
        XCTAssertTrue(nowhere.present, "a Topo standing nowhere lost the clock that places him")

        // A chat with no room anywhere, not even a pane: he stands nowhere.
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let window = try XCTUnwrap(stageWindow())
        defer { window.isHidden = true }
        window.addSubview(canvas)
        let none = MascotField(visible: CGRect(x: 0, y: 0, width: 400, height: 600),
                               obstacles: [CGRect(x: 0, y: 0, width: 400, height: 600)])
        canvas.apply(input: MascotState(model: "claude-sonnet-5").input, field: none, settings: Self.settings,
                     interval: 1.0 / 30, conditions: seen)
        XCTAssertEqual(canvas.roam?.hidden, true)
        for _ in 0..<30 { canvas.step(1.0 / 30) }
        XCTAssertEqual(canvas.driver.frames, 0, "a Topo standing nowhere was drawn")
        XCTAssertFalse(canvas.isTicking, "a Topo standing nowhere kept the link running")
        XCTAssertFalse(canvas.showing)
    }

    /// Something over him does not stop him being drawn: he is above everything in the chat.
    func testACoveredTopoIsStillDrawn() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let window = try XCTUnwrap(stageWindow())
        defer { window.isHidden = true }
        window.addSubview(canvas)
        let input = MascotState(model: "claude-sonnet-5").input
        canvas.apply(input: input, field: Self.open, settings: Self.settings, interval: 1.0 / 30, conditions: seen)
        for _ in 0..<30 { canvas.step(1.0 / 30) }
        let picture = try XCTUnwrap(canvas.roam?.picture)
        var over = Self.open
        over.obstacles = [picture.insetBy(dx: 4, dy: 4)]
        canvas.apply(input: input, field: over, settings: Self.settings, interval: 1.0 / 30, conditions: seen)
        XCTAssertEqual(canvas.roam?.covered, true)
        let before = canvas.driver.frames
        canvas.step(1.0 / 30)
        XCTAssertTrue(canvas.showing, "a covered Topo was not drawn")
        XCTAssertGreaterThan(canvas.driver.frames, before, "a covered Topo drew no frame")
    }

    /// The walk is worn only while his frame moves; on arrival he wears the activity he stands
    /// for, so a thinking guest goes on thinking rather than being put back to idle.
    func testTheWalkIsWornOnlyWhileHeGlidesAndHisActivitySurvivesIt() throws {
        let canvas = MascotCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let window = try XCTUnwrap(stageWindow())
        defer { window.isHidden = true }
        window.addSubview(canvas)
        let thinking = MascotState(model: "claude-sonnet-5", activity: .thinking).input
        func apply(_ field: MascotField) {
            canvas.apply(input: thinking, field: field, settings: Self.settings, interval: 1.0 / 30,
                         conditions: seen)
        }
        apply(Self.open)
        for _ in 0..<30 { canvas.step(1.0 / 30) }
        XCTAssertEqual(canvas.driver.input.activity, "thinking")
        let before = try XCTUnwrap(canvas.roam?.position)
        // A turn lands where he stands: he goes, walking.
        var landed = Self.open
        landed.obstacles = [CGRect(x: 0, y: before.y - 20, width: 400, height: 600 - before.y + 20)]
        apply(landed)
        var walked = false
        for _ in 0..<(30 * 30) {
            canvas.step(1.0 / 30)
            if canvas.roam?.walking == true {
                walked = true
                XCTAssertEqual(canvas.driver.input.activity, "walk")
            }
            if walked, canvas.roam?.walking == false { break }
        }
        XCTAssertTrue(walked, "he never glided")
        XCTAssertEqual(canvas.driver.input.activity, "thinking", "the glide put him back to something else")
        XCTAssertEqual(canvas.driver.input.corner, 0, "the engine's own stroll is not his to take")
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
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
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
