import CryptoKit
import XCTest

/// Types a dummy secret into a web page's password field in Safari, the way the sign-in types the
/// password (`scripts/simulator-run.sh --leak-check`, docs/simulator.md). The dummy is served as
/// the password is, and `TOPO_LEAKCHECK_ROUTE` says how it is typed: `redacted` through
/// `RedactedTyping`, as the sign-in does, or `typeText`, the control that shows the script's count
/// finds what XCTest records; with `TOPO_LEAKCHECK_FAIL` it fails once the dummy is typed, so the
/// script sees what a failing sign-in leaves. The script counts the dummy in what the run left;
/// this test only types it and says the field took it whole, by the hash of its value the page
/// shows, since a symbol typed as another keeps the length; a run whose hash is wrong fails before
/// the deliberate failure, and says which.
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
        case "redacted": try RedactedTyping.type(secret, into: field, record: "the dummy")
        case "typeText": field.typeText(secret)
        default: return XCTFail("TOPO_LEAKCHECK_ROUTE is \(route), not redacted or typeText")
        }
        let failing = env["TOPO_LEAKCHECK_FAIL"] == "1"
        let want = "sha " + SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        let digest = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                               object: safari.webViews.staticTexts[want])
        guard XCTWaiter().wait(for: [digest], timeout: 10) == .completed else {
            print("[leak-check] \(failing ? "failing" : route) typed the dummy wrong")
            return XCTFail("the field holds something other than the dummy")
        }
        print("[leak-check] \(failing ? "failing" : route) typed the dummy whole")
        if failing { XCTFail("failing after the dummy, as a stopped sign-in does") }
    }
}
