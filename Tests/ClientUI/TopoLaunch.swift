import XCTest

/// The app every UI suite launches: a debug build on the in-memory record store
/// (`TOPO_DEBUG_STORE=memory`, `AppRecords`), so the first screen waits on nothing but the app.
/// On real CloudKit an unsigned simulator's first reads after a fresh boot can take past a test's
/// wait for the chat (#434). The store is per process: a relaunch starts with no records, and what
/// a suite carries across one is on disk (the line's outbox, the defaults), as it is for the app.
enum TopoLaunch {
    static func app() -> TopoApplication {
        let app = TopoApplication()
        app.launchEnvironment["TOPO_DEBUG_STORE"] = "memory"
        return app
    }

    /// The system's alerts over the app (the permission prompts, the account alert): springboard's,
    /// asked for here so that no suite holds an application other than `TopoApplication`.
    static var springboardAlerts: XCUIElementQuery {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
    }
}

/// The one application the UI suites launch. On the quiet part of `topo_ui` the runner's
/// environment carries `TOPO_QUIET_LANE=1` (`TEST_RUNNER_TOPO_QUIET_LANE`, set by
/// `scripts/mac-suite.sh`), and every launch then holds the ear and the voice loading
/// (`TOPO_DEBUG_EAR`, `TOPO_DEBUG_VOICE`), whatever the suite set before it: the quiet part has
/// no audio lane and fetches no model. `activate()` launches an app that is not running, so it
/// holds them too. Final, so no subclass launches past it; the script refuses `XCUIApplication`
/// in any other file of the UI tests, so no suite makes an application that is not this one.
final class TopoApplication: XCUIApplication {
    static var quietLane: Bool { ProcessInfo.processInfo.environment["TOPO_QUIET_LANE"] == "1" }

    private func holdQuiet() {
        guard Self.quietLane else { return }
        launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
    }

    override func launch() {
        holdQuiet()
        super.launch()
    }

    override func activate() {
        holdQuiet()
        super.activate()
    }
}

extension XCUIElement {
    /// Scrolls `form` until this element sits in the middle half of what is on the screen of it,
    /// a few small drags at most. `isHittable` is true of a slider under the navigation bar or at
    /// the window's foot, where a drag on its thumb lands under the bars or off the screen and is
    /// lost, so reachable is not where a drag is made. Answers whether it got there.
    @MainActor
    @discardableResult
    func centred(in form: XCUIElement, window: XCUIElement, tries: Int = 8) -> Bool {
        let area = form.frame.intersection(window.frame)
        let low = area.minY + area.height * 0.25, high = area.minY + area.height * 0.75
        for _ in 0..<tries {
            guard exists else { return false }
            let middle = frame.midY
            if middle >= low, middle <= high { return true }
            // A short drag on the form's leading edge, clear of every control, the way the
            // content has to go.
            let from = middle > high ? 0.6 : 0.4, to = middle > high ? 0.4 : 0.6
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to)))
        }
        return frame.midY >= low && frame.midY <= high
    }
}
