import Darwin
import XCTest

/// Signs this simulator into an Apple Account through Settings, or signs it in again when the
/// account's sign-in has lapsed (`scripts/simulator-run.sh --sign-in`, docs/simulator.md).
///
/// The account arrives as `TOPO_SIGNIN_ACCOUNT`. The password never reaches the runner's
/// environment, which the result bundle's session log records whole: the script serves it once
/// on the host's loopback (`TOPO_SIGNIN_PORT`) to a request carrying `TOPO_SIGNIN_NONCE`, and
/// it is typed only into a secure field, whose typing XCTest logs as `<redacted>`.
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
        if let code = env["TOPO_SIGNIN_CODE"], !code.isEmpty {
            settings.activate()
            guard asksForCode(screenWords()) != nil else { return stopped("given a code, but no screen asks for one") }
            snap("code")
            settings.typeText(code)
            return try finish(accountCell)
        }
        settings.terminate()
        settings.activate()
        guard accountCell.waitForExistence(timeout: 20) else { return stopped("Settings showed no Apple Account cell") }
        snap("start")

        if accountCell.label.hasPrefix("Apple Account, Sign in") {
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
            print("[sign-in] already signed in as \(accountCell.label), and nothing asks for the password")
            return
        }

        // A first sign-in asks in Settings' sheet; a lapse's may ask in a SpringBoard alert.
        var field = settings.secureTextFields.firstMatch
        if !field.waitForExistence(timeout: 30) {
            field = springboard.secureTextFields.firstMatch
            guard field.exists else { return stopped("no password field") }
        }
        snap("password")
        let secret = try password()
        field.tap()
        field.typeText(secret)
        snap("typed")
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
        try finish(accountCell)
    }

    /// The screens after the password, until Settings shows the account signed in.
    private func finish(_ accountCell: XCUIElement) throws {
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
            // the account, agree to the terms, and decline the rest.
            if let answer = first(
                settings.buttons["Don’t Merge"], settings.buttons["Don't Merge"],
                settings.buttons["Agree"], springboard.buttons["Agree"], settings.alerts.buttons["Agree"],
                settings.buttons["Not Now"], springboard.buttons["Not Now"], settings.buttons["Skip"], settings.buttons["Later"]
            ) {
                print("[sign-in] step \(step): \(answer.label)")
                answer.tap()
                continue
            }
            // A short line, a heading or an alert's: a terms page's paragraphs say "passcode" too.
            if let passcode = words.first(where: { $0.count < 60 && $0.localizedCaseInsensitiveContains("passcode") }) {
                return stopped("the device asks for a passcode: \(passcode)")
            }
            let sheetUp = settings.secureTextFields.firstMatch.exists || settings.buttons["continue-button"].exists
            if !sheetUp, accountCell.exists, !accountCell.label.hasPrefix("Apple Account, Sign in"), lapsePrompt() == nil {
                snap("signed-in")
                print("[sign-in] signed in: \(accountCell.label)")
                return
            }
            if step % 5 == 0 { snap("waiting-\(step)") }
        }
        stopped("Settings did not show the account signed in within 120 s")
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

    /// The password, read once from the script's loopback listener.
    private func password() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let port = try XCTUnwrap(env["TOPO_SIGNIN_PORT"].flatMap(UInt16.init), "no TOPO_SIGNIN_PORT")
        let nonce = try XCTUnwrap(env["TOPO_SIGNIN_NONCE"], "no TOPO_SIGNIN_NONCE")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("socket: \(errno)") }
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
        guard connected == 0 else { throw failure("the password's listener refused the connection: \(errno)") }
        let ask = Array((nonce + "\n").utf8)
        guard write(fd, ask, ask.count) == ask.count else { throw failure("could not ask for the password: \(errno)") }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw failure("could not read the password: \(errno)") }
            if n == 0 { break }
            bytes += chunk[0..<n]
        }
        let password = String(decoding: bytes, as: UTF8.self)
        guard !password.isEmpty else { throw failure("the listener gave no password") }
        return password
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
