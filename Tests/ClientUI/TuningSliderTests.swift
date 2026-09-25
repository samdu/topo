import XCTest

/// The settings sheet's Tuning section in a running debug build: a slider moved there is worn by
/// the chat, and Reset gives the chat the look it had. Read off the badge's debug report
/// (`DebugRun.ChatReport.clearance`), which is the look in the chat's own environment.
@MainActor
final class TuningSliderTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheClearanceSliderIsWornByTheChatAndResetUndoesIt() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        // No tuning left over from an earlier run: the defaults' key is read as an empty document.
        app.launchArguments += ["-firstRunAnswered", "YES", "-topo.debug.tuning", "{}"]
        app.launch()
        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "the chat screen, with its badge")
        let shipped = try XCTUnwrap(clearance(in: app), "the report carries no clearance")
        XCTAssertGreaterThan(shipped, 0, "the shipped clearance is already the slider's bottom")

        let slider = try openTuning(app, badge: badge)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        // The slider's value is its field's, in points; halfway along 0...64 is 32.
        let moved = try XCTUnwrap((slider.value as? String).flatMap(Double.init), "the slider has no value")
        XCTAssertNotEqual(moved, shipped, "the slider did not move")
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: moved, in: app), "the chat does not wear the slider's \(moved): \(String(describing: clearance(in: app)))")

        _ = try openTuning(app, badge: badge)
        let reset = app.buttons["Reset"]
        XCTAssertTrue(reset.isEnabled, "Reset is not offered with a slider moved")
        reset.tap()
        XCTAssertFalse(reset.isEnabled, "Reset is still offered with nothing to reset")
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(wait(for: shipped, in: app), "Reset did not give the chat its look back: \(String(describing: clearance(in: app)))")
    }

    /// Opens the settings and scrolls to the Tuning section, which is the last in the sheet.
    private func openTuning(_ app: XCUIApplication, badge: XCUIElement) throws -> XCUIElement {
        badge.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "the tap did not open the settings")
        let slider = app.sliders["tuning-clearance"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<6 where !(slider.exists && slider.isHittable && app.buttons["Reset"].isHittable) {
            form.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(slider.isHittable, "the settings have no clearance slider")
        return slider
    }

    private func clearance(in app: XCUIApplication) -> Double? {
        struct Report: Decodable { var clearance: Double? }
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return (try? JSONDecoder().decode(Report.self, from: Data(raw.utf8)))?.clearance
    }

    private func wait(for wanted: Double, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let now = clearance(in: app), abs(now - wanted) < 0.001 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }
}
