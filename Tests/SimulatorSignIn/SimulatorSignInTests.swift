import Darwin
import XCTest

/// Signs this simulator into an Apple Account through Settings, or signs it in again when the
/// account's sign-in has lapsed (`scripts/simulator-run.sh --sign-in`, docs/simulator.md).
///
/// The account arrives as `TOPO_SIGNIN_ACCOUNT`. The password never reaches the runner's
/// environment, which the result bundle's session log records whole: the script serves it once
/// on the host's loopback (`TOPO_SIGNIN_PORT`) to a request carrying `TOPO_SIGNIN_NONCE`, and
/// it is typed only into a secure field, through `RedactedTyping` and never `typeText`, whose
/// activity title carries what it types.
///
/// It is typed once, and submitted only when the field holds as many characters as it has. A
/// refusal, a passcode or a screen this test does not know fails with what the screen showed, and
/// nothing is typed again: a password tried twice is an account Apple locks. A two-factor code
/// screen fails the same way and is left up; a run given the code (`TOPO_SIGNIN_CODE`) finds that
/// screen still standing and types the code into it, without opening Settings again.
@MainActor
final class SimulatorSignInTests: XCTestCase {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testSignIn() throws {
        let env = ProcessInfo.processInfo.environment
        let account = try XCTUnwrap(env["TOPO_SIGNIN_ACCOUNT"].flatMap { $0.isEmpty ? nil : $0 },
                                    "no TOPO_SIGNIN_ACCOUNT")
        let accountCell = settings.buttons["com.apple.settings.primaryAppleAccount"]
        // A run that resumes types nothing and asks for no password, a code included: it takes up
        // the screens after the password where a sign-in stopped on one it did not know.
        if env["TOPO_SIGNIN_RESUME"] == "1" {
            settings.activate()
            snap("resume")
            print("[sign-in] resuming the screens after the password")
            return try finish(accountCell, account: account)
        }
        if let code = env["TOPO_SIGNIN_CODE"], !code.isEmpty {
            settings.activate()
            guard asksForCode(screenWords()) != nil else { return stopped("given a code, but no screen asks for one") }
            snap("code")
            settings.typeText(code)
            return try finish(accountCell, account: account)
        }
        settings.terminate()
        settings.activate()
        guard accountCell.waitForExistence(timeout: 20) else { return stopped("Settings showed no Apple Account cell") }
        snap("start")

        // A sign-in that ended at a restart of the simulator shows nothing in Settings, and no
        // prompt can mend it (docs/simulator.md, *A lapse*): asked to renew, the account is signed
        // out first and signed in as on a device that never had one.
        if env["TOPO_SIGNIN_RENEW"] == "1", !accountCell.label.hasPrefix("Apple Account, Sign in"), lapsePrompt() == nil {
            guard shows(account, after: accountCell) else {
                return stopped("signed in to an account that is not \(account); sign it out by hand first")
            }
            if let why = signOut(accountCell, account: account) { return stopped(why) }
        }

        let firstSignIn = accountCell.label.hasPrefix("Apple Account, Sign in")
        if firstSignIn {
            accountCell.tap()
            let manual = settings.staticTexts["Sign in Manually"]
            guard manual.waitForExistence(timeout: 20) else { return stopped("no Sign in Manually") }
            manual.tap()
            let user = settings.textFields["username-field"]
            guard user.waitForExistence(timeout: 20) else { return stopped("no account field") }
            user.tap()
            user.typeText(account)
            settings.buttons["continue-button"].firstMatch.tap()
        } else if let prompt = awaitLapsePrompt() {
            print("[sign-in] signed in as \(accountCell.label); the sign-in is asked for again: \(prompt.label)")
            prompt.tap()
        } else {
            guard shows(account, after: accountCell) else {
                return stopped("signed in to an account that is not \(account); sign it out by hand first")
            }
            print("[sign-in] already signed in as \(account), and nothing asks for the password")
            return
        }

        // A first sign-in asks in Settings' sheet; a lapse's may ask in a SpringBoard alert.
        var field = settings.secureTextFields.firstMatch
        if !field.waitForExistence(timeout: 30) {
            field = springboard.secureTextFields.firstMatch
            guard field.exists else { return stopped("no password field") }
        }
        snap("password")
        // A lapse's prompt names the account it asks for: Buddy's password goes to no other.
        guard firstSignIn || screenWords().contains(where: { names($0, account) }) else {
            return stopped("the password prompt does not name \(account); nothing was typed")
        }
        let secret = try servedSecret()
        field.tap()
        // Never `typeText`, which writes what it types into its activity's title (RedactedTyping).
        do {
            try RedactedTyping.type(secret, into: field, record: "the password")
        } catch {
            return stopped("\(error)")
        }
        // A secure field shows its last character for a moment, and every screenshot is kept.
        sleep(3)
        let typed = (field.value as? String)?.count ?? 0
        guard typed == secret.count else {
            return stopped("the password field holds \(typed) characters, not \(secret.count); nothing was submitted")
        }
        // The sheet's Continue sits under the keyboard, whose return key is the form's own submit.
        guard let submit = first(settings.buttons["continue-button"], settings.buttons["Sign In"], springboard.buttons["Sign In"],
                                 settings.keyboards.buttons["Done"], settings.keyboards.buttons["Go"]) else {
            return stopped("no button submits the password; nothing was submitted")
        }
        submit.tap()
        try finish(accountCell, account: account)
    }

    /// The screens after the password, until Settings shows the account signed in.
    private func finish(_ accountCell: XCUIElement, account: String) throws {
        let deadline = Date().addingTimeInterval(120)
        var step = 0
        while Date() < deadline {
            sleep(2)
            step += 1
            let words = screenWords()
            if let refusal = words.first(where: { word in
                ["incorrect", "Verification Failed", "Unable to Sign In", "Could Not Sign In", "has been locked", "has been disabled"]
                    .contains { word.localizedCaseInsensitiveContains($0) }
            }) {
                return stopped("the password was refused: \(refusal)")
            }
            if let code = asksForCode(words) {
                return stopped("Apple asks for a two-factor code (\(code)); the screen is left up for SIGNIN_CODE=<code> scripts/simulator-run.sh --sign-in")
            }
            // What a first sign-in asks after the password: keep the simulator's own data out of
            // the account, agree to the terms, decline the rest, and go past what only informs
            // (Safety Settings' Continue).
            if let answer = first(
                settings.buttons["Don’t Merge"], settings.buttons["Don't Merge"],
                settings.buttons["Agree"], springboard.buttons["Agree"], settings.alerts.buttons["Agree"],
                settings.buttons["Not Now"], springboard.buttons["Not Now"], settings.buttons["Skip"], settings.buttons["Later"],
                settings.buttons["Continue"]
            ) {
                print("[sign-in] step \(step): \(answer.label)")
                answer.tap()
                continue
            }
            // A short line, a heading or an alert's: a terms page's paragraphs say "passcode" too.
            if let passcode = words.first(where: { $0.count < 60 && $0.localizedCaseInsensitiveContains("passcode") }) {
                return stopped("the device asks for a passcode: \(passcode)")
            }
            // Anything still standing over Settings, SpringBoard's alerts included, is a screen
            // the sign-in has not got past.
            let sheetUp = settings.secureTextFields.firstMatch.exists || springboard.secureTextFields.firstMatch.exists
                || settings.buttons["continue-button"].exists || springboard.alerts.firstMatch.exists
                || settings.alerts.firstMatch.exists
            if !sheetUp, accountCell.exists, accountCell.isHittable, !accountCell.label.hasPrefix("Apple Account, Sign in"),
               lapsePrompt() == nil {
                let label = accountCell.label
                guard shows(account, after: accountCell) else {
                    return stopped("Settings shows an account, but its page does not name \(account)")
                }
                snap("signed-in")
                print("[sign-in] signed in: \(account) (\(label))")
                return
            }
            // A sign-in that went through the account's own page ends there: its Sign Out and
            // the account named on it are the account signed in.
            let whole = Self.wholePattern(account)
            if !sheetUp, lapsePrompt() == nil, settings.buttons["AAUIDeleteButtonSpecifierID"].exists,
               settings.staticTexts.matching(NSPredicate(format: "label MATCHES %@", whole)).firstMatch.exists {
                snap("signed-in")
                print("[sign-in] signed in: \(account) (its account page)")
                return
            }
            if step % 5 == 0 { snap("waiting-\(step)") }
        }
        stopped("Settings did not show the account signed in within 120 s")
    }

    /// Signs the account out from its own page, which `shows` left open, answering the sheets on
    /// the way, until Settings offers a sign-in: nil then, or why it stopped. Nothing is typed: a
    /// sign-out that asks for the password (Find My, on a phone) stops here.
    private func signOut(_ accountCell: XCUIElement, account: String) -> String? {
        let button = settings.buttons["AAUIDeleteButtonSpecifierID"].firstMatch
        var swipes = 0
        while !(button.exists && button.isHittable), swipes < 8 {
            settings.swipeUp()
            swipes += 1
        }
        guard button.exists, button.isHittable else { return "the account's page has no Sign Out" }
        snap("sign-out")
        print("[sign-in] signing \(account) out, to sign it in again")
        settings.cells["AAUIDeleteButtonSpecifierID"].firstMatch.tap()
        // The page's own Sign Out stays under whatever it opens, so a confirmation is any other
        // button of that name, Settings' or SpringBoard's. Nothing that erases is ever tapped.
        let other = NSPredicate(format: "label == 'Sign Out' AND identifier != 'AAUIDeleteButtonSpecifierID'")
        let deadline = Date().addingTimeInterval(120)
        var step = 0
        while Date() < deadline {
            sleep(2)
            step += 1
            snap("signing-out-\(step)")
            print("[sign-in] sign-out step \(step) shows: \(screenWords().prefix(12).joined(separator: " | "))")
            if settings.secureTextFields.firstMatch.exists || springboard.secureTextFields.firstMatch.exists {
                return "signing out asks for a password; nothing was typed"
            }
            // iOS asks whether to erase the device after signing out, and the answer is never to;
            // then says most data stays on the device (Continue), and that what an app has not
            // synced goes (Continue Anyway: the simulator keeps nothing of its own). An alert
            // stands over the sheet under it, so alerts are answered first.
            if let answer = first(settings.alerts.buttons["Continue Anyway"], springboard.alerts.buttons["Continue Anyway"],
                                  springboard.alerts.buttons.matching(other).firstMatch, settings.alerts.buttons.matching(other).firstMatch,
                                  settings.buttons["Sign Out But Don’t Erase"], settings.buttons["Sign Out But Don't Erase"],
                                  settings.buttons["Continue"],
                                  settings.sheets.buttons.matching(other).firstMatch, settings.buttons.matching(other).firstMatch) {
                print("[sign-in] sign-out step \(step): tapped \(answer.label)")
                answer.tap()
                continue
            }
            // Signed out, Settings goes back to its list, where the cell offers a sign-in.
            if accountCell.exists, accountCell.label.hasPrefix("Apple Account, Sign in") {
                snap("signed-out")
                print("[sign-in] signed out")
                return nil
            }
        }
        return "Settings did not offer a sign-in within 120 s of Sign Out"
    }

    /// Whether the account's own page, opened from its cell, names this account.
    private func shows(_ account: String, after accountCell: XCUIElement) -> Bool {
        accountCell.tap()
        let whole = Self.wholePattern(account)
        let named = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", whole, whole)).firstMatch
        return named.waitForExistence(timeout: 15)
    }

    /// Whether a screen's words name this account whole: `notbuddy@…` is not `buddy@…`.
    private func names(_ words: String, _ account: String) -> Bool {
        words.range(of: Self.wholePattern(account), options: .regularExpression) != nil
    }

    /// The account as a whole address among other words: no character an address can hold
    /// on either side of it (a sentence's full stop aside), case aside.
    private static func wholePattern(_ account: String) -> String {
        let edge = #"[^\p{L}\p{N}\.\_\%\+\@\!\#\$\&\'\*\/\=\?\^\`\{\|\}\~\-]"#
        return "(?is).*(^|\(edge))\(NSRegularExpression.escapedPattern(for: account))\\.?(\(edge)|$).*"
    }

    private func asksForCode(_ words: [String]) -> String? {
        words.first { word in
            ["verification code", "Two-Factor", "Enter the code", "6-digit"].contains { word.localizedCaseInsensitiveContains($0) }
        }
    }

    /// A lapse's prompt, given the few seconds it takes to appear after Settings opens.
    private func awaitLapsePrompt() -> XCUIElement? {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let prompt = lapsePrompt() { return prompt }
            sleep(1)
        } while Date() < deadline
        return nil
    }

    /// What a lapsed sign-in shows: the Apple Account Verification alert, SpringBoard's or
    /// Settings', or the account's row in Settings asking for the password again.
    private func lapsePrompt() -> XCUIElement? {
        for app in [springboard, settings] {
            let alert = app.alerts.firstMatch
            if alert.exists, alert.label.localizedCaseInsensitiveContains("Apple Account"), alert.buttons["Settings"].exists {
                return alert.buttons["Settings"].firstMatch
            }
        }
        for label in ["Apple Account Sign In Required", "Sign In Required", "Update Apple Account Settings"] {
            let row = settings.cells.containing(.staticText, identifier: label).firstMatch
            if row.exists { return row }
            let text = settings.staticTexts[label]
            if text.exists { return text }
        }
        return nil
    }


    private func first(_ candidates: XCUIElement...) -> XCUIElement? {
        // A sheet's buttons are in the hierarchy twice, and a query matching two cannot be asked
        // whether it is hittable.
        candidates.lazy.map(\.firstMatch).first { $0.exists && $0.isHittable }
    }

    /// Every static text the sign-in shows, and Settings' and SpringBoard's alerts'. Settings' own
    /// list stays in the hierarchy under the sheet, and its rows ("Face ID & Passcode") are not
    /// the sign-in's words.
    private func screenWords() -> [String] {
        let list = Set(settings.collectionViews["com.apple.settings.sidebar.collectionView"]
            .staticTexts.allElementsBoundByIndex.map(\.label))
        var words = settings.staticTexts.allElementsBoundByIndex.map(\.label).filter { !list.contains($0) }
        words += settings.alerts.allElementsBoundByIndex.map(\.label)
        words += springboard.alerts.allElementsBoundByIndex.flatMap { [$0.label] + $0.staticTexts.allElementsBoundByIndex.map(\.label) }
        return words
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func stopped(_ why: String) {
        snap("stopped")
        print("[sign-in] stopped: \(why)\n\(settings.debugDescription)")
        XCTFail("sign-in stopped: \(why)")
    }

    private func failure(_ why: String) -> Error {
        NSError(domain: "SimulatorSignIn", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
    }
}

/// The secret the script serves once on the host's loopback (`TOPO_SIGNIN_PORT`), to a request
/// carrying `TOPO_SIGNIN_NONCE`: the password for a sign-in, a dummy for a leak check.
func servedSecret() throws -> String {
    let env = ProcessInfo.processInfo.environment
    let port = try XCTUnwrap(env["TOPO_SIGNIN_PORT"].flatMap(UInt16.init), "no TOPO_SIGNIN_PORT")
    let nonce = try XCTUnwrap(env["TOPO_SIGNIN_NONCE"], "no TOPO_SIGNIN_NONCE")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw served("socket: \(errno)") }
    defer { close(fd) }
    var bound = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw served("the password's listener refused the connection: \(errno)") }
    let ask = Array((nonce + "\n").utf8)
    guard write(fd, ask, ask.count) == ask.count else { throw served("could not ask for the password: \(errno)") }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 256)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { throw served("could not read the password: \(errno)") }
        if n == 0 { break }
        bytes += chunk[0..<n]
    }
    let password = String(decoding: bytes, as: UTF8.self)
    guard !password.isEmpty else { throw served("the listener gave no password") }
    return password
}

private func served(_ why: String) -> Error {
    NSError(domain: "SimulatorSignIn", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
}
