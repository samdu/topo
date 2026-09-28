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
        done(app)
        XCTAssertTrue(wait(for: moved, in: app), "the chat does not wear the slider's \(moved): \(String(describing: clearance(in: app)))")

        _ = try openTuning(app, badge: badge)
        let reset = app.buttons["Reset"]
        XCTAssertTrue(reset.isEnabled, "Reset is not offered with a slider moved")
        reset.tap()
        XCTAssertTrue(becomes(reset, "isEnabled == false"), "Reset is still offered with nothing to reset")
        done(app)
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
        XCTAssertTrue(becomes(reset, "isEnabled == false"), "Reset is still offered with nothing to reset")
        XCTAssertTrue(becomes(pin, "exists == false"), "the pin is still shown after Reset")
        done(app)
        XCTAssertTrue(wait(in: app) { $0.placement == "roam" && $0.overridePlacement == nil },
                      "Reset did not give him his roaming back")

        _ = try openTuning(app, badge: badge)
        let picker = app.buttons["tuning-placement"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the section has no placement")
        picker.tap()
        let glass = app.buttons["On the glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 5), "the placement offers no glass")
        let chosen = "label CONTAINS 'On the glass' OR value CONTAINS 'On the glass'"
        glass.tap()
        // A tap reaching a starved app can be lost, leaving the menu up, open in full, with nothing
        // chosen. This is a retry, not a wait for readiness: the tap is made again only while the
        // menu is still up to be hit and the picker still shows no glass, twice more at most, and
        // each one is logged; what the chat wears is still held below.
        for _ in 0..<2 where !becomes(glass, "exists == false", timeout: 3)
            && glass.isHittable && !becomes(picker, chosen, timeout: 0.5) {
            print("retapped On the glass: menu still up")
            glass.tap()
        }
        // The menu is gone and the choice is the picker's before the sheet is closed: a tap on
        // Done while the menu is still going lands on nothing and leaves the sheet up.
        XCTAssertTrue(becomes(glass, "exists == false"), "the placement menu did not close")
        XCTAssertTrue(becomes(picker, chosen),
                      "the picker does not show the glass chosen: \(picker.label) \(String(describing: picker.value))")
        done(app)
        XCTAssertTrue(wait(in: app) { $0.placement == "glass" && $0.overridePlacement == "glass" && $0.presence == 1 },
                      "the chat does not wear the glass chosen, on a pane drawn whole")
    }

    /// Waits, bounded, for `element` to be as `predicate` says: what a tap changes is drawn by the
    /// app's next update, which a snapshot taken on the line after the tap can come before.
    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Closes the settings with Done once it can be hit, and waits for the sheet to be gone, so
    /// what is read next is the chat and not the sheet over it.
    private func done(_ app: XCUIApplication) {
        let settings = app.navigationBars["Settings"]
        let done = settings.buttons["Done"]
        XCTAssertTrue(becomes(done, "hittable == true"), "Done cannot be hit")
        done.tap()
        XCTAssertTrue(becomes(settings, "exists == false"), "Done did not close the settings")
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

    /// Opens the settings and scrolls to the Tuning section, which is the last in the sheet, until
    /// Reset, its last row, can be hit. Each scroll is a drag held a moment first: a fling handed
    /// to a starved app can arrive as a touch too short to move the list, so the list is dragged
    /// until it gets there, a bounded number of times, from the leading margin, where no row's
    /// control is to be picked up by it.
    private func openTuning(_ app: XCUIApplication, badge: XCUIElement) throws -> XCUIElement {
        badge.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "the tap did not open the settings")
        let slider = app.sliders["tuning-clearance"]
        let reset = app.buttons["Reset"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<10 where !(slider.exists && slider.isHittable && reset.exists && reset.isHittable) {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3)))
        }
        XCTAssertTrue(slider.isHittable, "the settings have no clearance slider")
        XCTAssertTrue(reset.exists && reset.isHittable, "the settings have no Reset")
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
