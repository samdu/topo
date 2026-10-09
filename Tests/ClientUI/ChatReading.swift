import XCTest

/// What the UI suites read off the running chat: Topo and the look he is placed by, off the badge's
/// debug report (`DebugRun.ChatReport`), and the microphone's counters, off its own
/// (`VoiceInput.Report`). Both are debug-only accessibility values.
enum ChatReading {
    /// The button's labels: `VoiceInput`'s state in words, or Stop while Topo is speaking.
    static let labels = ["Hold to talk", "Listening; release to send", "Listening; press to send", "Stop speaking"]

    struct Chat: Decodable {
        var mascot: Topo?
        var facing: String?
        var placement: String?
        var pin: [Double]?
        var overridePlacement: String?
        var overridePin: [Double]?
        var presence: Double?
        var contentBottom: Double?
        /// The addresses taps on a reply's links asked to be opened, in order.
        var opened: [String]?
        /// Whether the guest's home is mounted in this launch.
        var guestHome: Bool?
        /// The model the bar's menu last set, by its alias, and the model a request carries for
        /// it, which in a debug build is the pin.
        var model: String?
        var effectiveModel: String?
    }

    struct Topo: Decodable, CustomStringConvertible {
        var roost = ""
        var frame: [Double]?
        var to: [Double]?
        var hidden = true
        var walking = false
        var covered = false
        var moves = 0
        var pane: [Double]?
        var placement = ""
        var dragging = false
        var drags = 0
        var pin: [Double]?
        var well: [Double]?
        var visible: [Double]?
        /// The last reports, oldest first, and what the glass drew while something moved.
        var recent: [Glimpse] = []
        var trail: [Drawn] = []
        /// The roam's last decision where to stand, as the report sums it up.
        var decision: Decision?

        struct Decision: Decodable {
            var chosen: [Double]?
            var clears: Bool?
            var cost: Double?
            var candidates: Int
            var clearing: Int
        }

        struct Glimpse: Decodable {
            var sequence: Int
            var frame: [Double]?
            var hidden: Bool
        }

        struct Drawn: Decodable, Equatable, CustomStringConvertible {
            var t: Double
            var top: Double
            var keyboard: Double
            var moving: Bool
            var description: String { String(format: "%.3f top %.1f keyboard %.1f%@", t, top, keyboard, moving ? " moving" : "") }
        }

        var description: String {
            "\(roost) (\(placement)) at \(frame ?? []) to \(to ?? []) hidden \(hidden) walking \(walking) dragging \(dragging) drags \(drags) moves \(moves) pin \(pin ?? []) pane \(pane ?? []) well \(well ?? []) decision \(decision.map { "chosen \($0.chosen ?? []) clears \($0.clears.map(String.init) ?? "-") cost \($0.cost ?? -1) of \($0.candidates), \($0.clearing) clear" } ?? "none") trail \(trail.suffix(30))"
        }

        /// Standing still where his roost has him.
        var standing: Bool { !hidden && !walking && !dragging && frame != nil && frame == to }

        var box: CGRect? { frame.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        var paneRect: CGRect? { pane.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        var wellRect: CGRect? { well.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        var visibleRect: CGRect? { visible.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }

        /// What a pin is a fraction of: the transcript's frame carried down to the pane's foot.
        var pinFrame: CGRect? {
            guard let visible = visibleRect else { return nil }
            guard let pane = paneRect, pane.maxY > visible.maxY else { return visible }
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: pane.maxY - visible.minY)
        }
    }

    /// Two reported frames the same to a hundredth of a point: a pin read back from a place is
    /// that place to a rounding.
    static func near(_ a: [Double]?, _ b: [Double]?) -> Bool {
        guard let a, let b, a.count == b.count else { return a == nil && b == nil }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    struct Mic: Decodable {
        var presses: Int
        var releases: Int
    }

    static func chat(_ app: XCUIApplication) -> Chat? {
        let raw = app.buttons["topo-debug-chat"].value as? String ?? ""
        return try? JSONDecoder().decode(Chat.self, from: Data(raw.utf8))
    }

    static func mic(_ element: XCUIElement) -> Mic? {
        let raw = element.value as? String ?? ""
        return try? JSONDecoder().decode(Mic.self, from: Data(raw.utf8))
    }

    static func microphone(_ app: XCUIApplication) -> XCUIElement {
        app.images.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// The offset from the space Topo reports in to the screen's: the well he read against the
    /// microphone the system finds, which is the same view.
    static func offset(_ topo: Topo, mic: XCUIElement) -> CGVector? {
        guard let well = topo.wellRect else { return nil }
        return CGVector(dx: mic.frame.minX - well.minX, dy: mic.frame.minY - well.minY)
    }

    /// Launches the chat over a fixture transcript with the ear and the voice held loading, the
    /// override (`TOPO_DEBUG_TUNING`) set to `tuning` — empty removes it, nil leaves what the last
    /// launch kept — the look `look` in place of the vault's, and anything in `environment` besides.
    static func launch(transcript: String, tuning: String?, look: String = "{}",
                       softwareKeyboard: Bool = false, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, given in given }
        if softwareKeyboard { app.launchEnvironment["TOPO_DEBUG_SOFTWARE_KEYBOARD"] = "1" }
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchEnvironment["TOPO_DEBUG_LOOK"] = look
        app.launchEnvironment["TOPO_DEBUG_TRANSCRIPT"] = transcript
        if let tuning { app.launchEnvironment["TOPO_DEBUG_TUNING"] = tuning }
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        dismissAccountAlert()
        return app
    }

    /// A simulator signed into iCloud can ask for the account's password over the app; it is the
    /// simulator's alert and not Topo's, so it is put away.
    static func dismissAccountAlert(timeout: TimeInterval = 3) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Apple Account Verification"]
        if alert.waitForExistence(timeout: timeout) { alert.buttons["Not Now"].tap() }
    }

    /// Every permission alert this run has answered, across every class's tests: the runner keeps
    /// one process for them, and the grant one test gives stands for the rest. `MicrophonePressTests`
    /// holds the count.
    @MainActor static var promptsAnswered: [String] = []

    /// A microphone prompt a press raised, in a test that comes before `MicrophonePressTests` or
    /// on a lane run alone, is answered and counted.
    @MainActor static func answerPrompt() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
            .filter { !$0.isEmpty }.joined(separator: " — ")
        let allow = alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch
        guard allow.waitForExistence(timeout: 3) else { return }
        allow.tap()
        promptsAnswered.append(text)
    }

    struct NotThere: Error, CustomStringConvertible { var description: String }

    /// Waits for the chat's report to be as `wanted` says; fails naming what it was instead.
    @discardableResult
    static func wait(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line,
                     _ wanted: (Chat, Topo) -> Bool) throws -> (Chat, Topo) {
        var seen: Chat?
        if let found = poll(app, timeout: timeout, seen: &seen, wanted) { return found }
        let message = "Topo was not \(what) in \(timeout) s: \(seen?.mascot.map(String.init(describing:)) ?? "never reported")"
        XCTFail(message, file: file, line: line)
        throw NotThere(description: message)
    }

    /// The chat's report once it is as `wanted` says, or nil when `timeout` runs out first, with
    /// the last report read in `seen`.
    static func poll(_ app: XCUIApplication, timeout: TimeInterval, seen: inout Chat?,
                     _ wanted: (Chat, Topo) -> Bool) -> (Chat, Topo)? {
        let deadline = Date().addingTimeInterval(timeout)
        let account = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Apple Account Verification"]
        seen = chat(app)
        while !(seen.flatMap { chat in chat.mascot.map { wanted(chat, $0) } } ?? false), Date() < deadline {
            if account.exists { account.buttons["Not Now"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            seen = chat(app)
        }
        guard let seen, let topo = seen.mascot, wanted(seen, topo) else { return nil }
        return (seen, topo)
    }

    static func poll(_ app: XCUIApplication, timeout: TimeInterval, _ wanted: (Chat, Topo) -> Bool) -> (Chat, Topo)? {
        var seen: Chat?
        return poll(app, timeout: timeout, seen: &seen, wanted)
    }

    /// The field in the glass. A vertically growing `TextField` is a text view to XCUITest, and a
    /// one-line one is a text field, so both are asked for by the label the pane gives it. It is
    /// one view in both of the pane's forms, and the system's text view stays in the accessibility
    /// tree whatever is drawn of it, so it exists at rest too: `fieldShown` says whether the pane
    /// is the row it is drawn in.
    static func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'What to say'")).firstMatch
    }

    /// Whether the pane is the row the field is drawn in: the send beside it is there, and the
    /// way to the keyboard, which the row has no place for, is not.
    static func fieldShown(_ app: XCUIApplication) -> Bool {
        field(app).exists && app.buttons["Send"].exists && !app.buttons["Type instead"].exists
    }

    /// Raises the keyboard with the mark on the resting pane that raises it, a simulator's late
    /// account alert taking the first tap at most twice.
    static func raiseKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let mark = app.buttons["Type instead"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "the way to the keyboard", file: file, line: line)
        for _ in 0..<3 where !app.keyboards.element.exists {
            mark.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { break }
            dismissAccountAlert()
        }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the mark raised no keyboard", file: file, line: line)
    }

    /// A point in the transcript's own empty space: in the margin beside the turns, which no turn
    /// of any transcript is drawn in, a little under the navigation bar.
    static func emptySpace(_ app: XCUIApplication) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 5, dy: 180))
    }

    /// Lowers the keyboard as a person does, with a tap on the transcript's empty space.
    static func lowerKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.keyboards.element.exists, "no keyboard to lower", file: file, line: line)
        emptySpace(app).tap()
        XCTAssertTrue(keyboardGone(app), "the keyboard did not go", file: file, line: line)
    }

    /// Waits, bounded, for the keyboard to be off the screen.
    static func keyboardGone(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.keyboards.element.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return !app.keyboards.element.exists
    }

    static func attach(_ app: XCUIApplication, _ name: String, to test: XCTestCase) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }
}
