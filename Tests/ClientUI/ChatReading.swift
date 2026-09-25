import XCTest

/// What the UI suites read off the running chat: Topo and the look he is placed by, off the badge's
/// debug report (`DebugRun.ChatReport`), and the microphone's counters, off its own
/// (`VoiceInput.Report`). Both are debug-only accessibility values.
enum ChatReading {
    /// The button's three labels, `VoiceInput`'s state in words.
    static let labels = ["Hold to talk", "Listening; release to send", "Listening; press to send"]

    struct Chat: Decodable {
        var mascot: Topo?
        var facing: String?
        var placement: String?
        var pin: [Double]?
        var overridePlacement: String?
        var overridePin: [Double]?
        var presence: Double?
        var contentBottom: Double?
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
        /// The last reports, oldest first.
        var recent: [Glimpse] = []

        struct Glimpse: Decodable {
            var sequence: Int
            var frame: [Double]?
            var hidden: Bool
        }

        var description: String { String(format: "%.3f top %.1f keyboard %.1f%@", t, top, keyboard, moving ? " moving" : "") }
        }

        var description: String {
            "\(roost) (\(placement)) at \(frame ?? []) to \(to ?? []) hidden \(hidden) walking \(walking) dragging \(dragging) drags \(drags) moves \(moves) pin \(pin ?? []) pane \(pane ?? []) well \(well ?? [])"
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
    /// launch kept — and the look `look` in place of the vault's.
    static func launch(transcript: String, tuning: String?, look: String = "{}",
                       softwareKeyboard: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
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

    /// A microphone prompt a press raised, on a lane run alone, is answered.
    static func answerPrompt() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch.tap()
        }
    }

    struct NotThere: Error, CustomStringConvertible { var description: String }

    /// Waits for the chat's report to be as `wanted` says; fails naming what it was instead.
    @discardableResult
    static func wait(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line,
                     _ wanted: (Chat, Topo) -> Bool) throws -> (Chat, Topo) {
        let deadline = Date().addingTimeInterval(timeout)
        let account = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Apple Account Verification"]
        var seen = chat(app)
        while !(seen.flatMap { chat in chat.mascot.map { wanted(chat, $0) } } ?? false), Date() < deadline {
            if account.exists { account.buttons["Not Now"].tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            seen = chat(app)
        }
        guard let seen, let topo = seen.mascot, wanted(seen, topo) else {
            let message = "Topo was not \(what) in \(timeout) s: \(seen?.mascot.map(String.init(describing:)) ?? "never reported")"
            XCTFail(message, file: file, line: line)
            throw NotThere(description: message)
        }
        return (seen, topo)
    }

    /// Raises the keyboard with the flank that raises it, a simulator's late account alert taking
    /// the first tap at most twice.
    static func raiseKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 10), "the keyboard flank", file: file, line: line)
        for _ in 0..<3 where !app.keyboards.element.exists {
            flank.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) { break }
            dismissAccountAlert()
        }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the flank raised no keyboard", file: file, line: line)
    }

    static func lowerKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let flank = app.buttons["Hide the keyboard"]
        XCTAssertTrue(flank.waitForExistence(timeout: 10), "the flank that lowers the keyboard", file: file, line: line)
        flank.tap()
        let deadline = Date().addingTimeInterval(10)
        while app.keyboards.element.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(app.keyboards.element.exists, "the keyboard did not go", file: file, line: line)
    }

    static func attach(_ app: XCUIApplication, _ name: String, to test: XCTestCase) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        test.add(shot)
    }
}
