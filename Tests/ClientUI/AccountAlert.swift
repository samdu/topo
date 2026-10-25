import XCTest

/// A simulator signed into iCloud can put its own "Apple Account Verification" alert over the app
/// at any point of a run; it is the simulator's and not Topo's. The bundle's principal class
/// (`NSPrincipalClass`, `project.yml`), so XCTest makes one before any test runs: it gives every
/// test case a UI interruption monitor that puts that alert away with Not Now when it stands in
/// the way of the next interaction, and leaves every other alert to the test (a permission prompt
/// is answered and counted by `ChatReading.answerPrompt`, never here). A launch looks for the
/// alert once without waiting (`ChatReading.dismissAccountAlert`), and the waits that read the
/// chat put it away whenever it is up (`ChatReading.poll`).
final class AccountAlert: NSObject, XCTestObservation {
    static let title = "Apple Account Verification"

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        // XCTest tells its observers on the main thread, where the test case runs.
        nonisolated(unsafe) let testCase = testCase
        MainActor.assumeIsolated {
            _ = testCase.addUIInterruptionMonitor(withDescription: Self.title) { alert in
                guard alert.label == Self.title || alert.staticTexts[Self.title].exists else { return false }
                let notNow = alert.buttons["Not Now"]
                guard notNow.exists else { return false }
                notNow.tap()
                return true
            }
        }
    }
}
