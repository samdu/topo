import XCTest

/// Types a dummy secret into a web page's password field in Safari, the way the sign-in types the
/// password (`scripts/simulator-run.sh --leak-check`, docs/simulator.md). The dummy is served as
/// the password is, and `TOPO_LEAKCHECK_ROUTE` says how it is typed: `redacted` through
/// `RedactedTyping`, as the sign-in does, or `typeText`, the control that shows the script's count
/// finds what XCTest records. The script counts the dummy in what the run left; this test only
/// types it and says the field took it whole.
@MainActor
final class LeakCheckTests: XCTestCase {
    func testLeakCheck() throws {
        let env = ProcessInfo.processInfo.environment
        let route = try XCTUnwrap(env["TOPO_LEAKCHECK_ROUTE"], "no TOPO_LEAKCHECK_ROUTE")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        let field = safari.webViews.secureTextFields.firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !field.exists, Date() < deadline {
            // A first launch of Safari puts its own sheet over the page.
            for label in ["Continue", "Not Now", "Close"] where safari.buttons[label].exists {
                safari.buttons[label].firstMatch.tap()
            }
            _ = field.waitForExistence(timeout: 2)
        }
        guard field.exists else { return XCTFail("the leak check's page shows no password field") }
        let secret = try servedSecret()
        field.tap()
        switch route {
        case "redacted": try RedactedTyping.type(secret, record: "the dummy")
        case "typeText": field.typeText(secret)
        default: return XCTFail("TOPO_LEAKCHECK_ROUTE is \(route), not redacted or typeText")
        }
        sleep(2)
        let typed = (field.value as? String)?.count ?? 0
        print("[leak-check] \(route) typed \(typed) of \(secret.count) characters")
        XCTAssertEqual(typed, secret.count, "the field holds \(typed) characters, not \(secret.count)")
    }
}
