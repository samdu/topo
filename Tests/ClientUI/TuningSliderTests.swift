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
        // No tuning left over from an earlier run: the override is removed at launch.
        app.launchEnvironment["TOPO_DEBUG_TUNING"] = ""
        app.launchArguments += ["-firstRunAnswered", "YES"]
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

    /// The Tuning section shows where Topo sits and the pin a drag left, and offers Reset: with a
    /// pin kept, the section says so, Reset gives the chat its roaming back; the placement chosen
    /// there, `glass`, is what the chat wears.
    func testTheSectionShowsThePlacementAndThePinAndResetRemovesThem() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_TRANSCRIPT"] = "empty"
        app.launchEnvironment["TOPO_DEBUG_TUNING"] = #"{"mascot": {"placement": "pinned", "pin": {"x": 0.25, "y": 0.5}}}"#
        app.launchArguments += ["-firstRunAnswered", "YES"]
        addTeardownBlock {
            let clean = XCUIApplication()
            clean.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
            clean.launchEnvironment["TOPO_DEBUG_TUNING"] = ""
            clean.launch()
            clean.terminate()
        }
        app.launch()
        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "the chat screen, with its badge")
        XCTAssertTrue(wait(in: app) { $0.placement == "pinned" }, "the chat does not wear the kept pin")

        _ = try openTuning(app, badge: badge)
        let pin = app.descendants(matching: .any)["tuning-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "the section does not show the pin")
        XCTAssertTrue(pin.label.contains("25% across") || (pin.value as? String ?? "").contains("25% across"),
                      "the pin shown is not the kept one: \(pin.label) \(String(describing: pin.value))")
        let reset = app.buttons["Reset"]
        XCTAssertTrue(reset.isEnabled, "Reset is not offered with a pin kept")
        reset.tap()
        XCTAssertFalse(reset.isEnabled, "Reset is still offered with nothing to reset")
        XCTAssertFalse(pin.exists, "the pin is still shown after Reset")
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(wait(in: app) { $0.placement == "roam" && $0.overridePlacement == nil },
                      "Reset did not give him his roaming back")

        _ = try openTuning(app, badge: badge)
        let picker = app.buttons["tuning-placement"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the section has no placement")
        picker.tap()
        let glass = app.buttons["On the glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 5), "the placement offers no glass")
        glass.tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(wait(in: app) { $0.placement == "glass" && $0.overridePlacement == "glass" && $0.presence == 1 },
                      "the chat does not wear the glass chosen, on a pane drawn whole")
    }

    private struct Placed: Decodable {
        var placement: String?
        var overridePlacement: String?
        var presence: Double?
    }

    private func wait(in app: XCUIApplication, _ wanted: (Placed) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
            if let placed = try? JSONDecoder().decode(Placed.self, from: Data(raw.utf8)), wanted(placed) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
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
