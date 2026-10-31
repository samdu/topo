import AuthenticationServices
import Foundation
import TopoAuth
import XCTest
@testable import Topo

/// The sign-in's browser sheet (`WebAuth`): only the person closing the sheet that is up is a
/// dismissal. One the app closed, or replaced with the next authorization, tells nobody, however
/// late its own ending is reported, and neither does one the system would not present.
@MainActor
final class WebAuthTests: XCTestCase {
    private final class Sheet: WebAuth.Sheet {
        let ended: @Sendable (WebAuth.Ending) -> Void
        let taken: Bool
        var began = 0, cancelled = 0
        init(taken: Bool, ended: @escaping @Sendable (WebAuth.Ending) -> Void) {
            self.taken = taken
            self.ended = ended
        }
        func begin() -> Bool { began += 1; return taken }
        func cancel() { cancelled += 1 }
    }

    /// A `WebAuth` over sheets the test holds, in an app the test says is active or not.
    @MainActor private final class Stage {
        let web = WebAuth()
        var sheets: [Sheet] = []
        var urls: [String] = []
        var active = true
        /// Whether the system takes the next sheets begun.
        var takes = true
        var dismissed: [String] = []

        init() {
            web.isActive = { [unowned self] in active }
            web.makeSheet = { [unowned self] url, ended in
                let sheet = Sheet(taken: takes, ended: ended)
                sheets.append(sheet)
                urls.append(url.lastPathComponent)
                return sheet
            }
        }

        func open(_ name: String) {
            web.open(URL(string: "https://example.com/\(name)")!) { [unowned self] in dismissed.append(name) }
        }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testOnlyTheSheetThatIsUpReportsItsDismissal() async {
        let stage = Stage()
        stage.open("login")
        // The login landed: the sign-in opens the guest's authorization in the login's place.
        stage.open("guest")
        XCTAssertEqual(stage.sheets.map(\.began), [1, 1])
        XCTAssertEqual(stage.sheets.map(\.cancelled), [1, 0], "the replaced sheet was left up")
        // The replaced sheet reports its ending late, either way.
        stage.sheets[0].ended(.dismissed)
        stage.sheets[0].ended(.refused)
        await settle()
        XCTAssertEqual(stage.dismissed, [], "a sheet the app replaced was taken for the person closing it")
        XCTAssertEqual(stage.sheets.count, 2, "a replaced sheet's ending opened another")

        // The app closes the second on a finished sign-in; its ending is nobody's dismissal either.
        stage.web.close()
        stage.sheets[1].ended(.dismissed)
        await settle()
        XCTAssertEqual(stage.dismissed, [])
        XCTAssertEqual(stage.sheets[1].cancelled, 1)

        // A sheet the person closes is reported, once.
        stage.open("again")
        stage.sheets[2].ended(.dismissed)
        stage.sheets[2].ended(.dismissed)
        await settle()
        XCTAssertEqual(stage.dismissed, ["again"])
    }

    /// The system presents no sheet while the app is not active, which is where a sign-in
    /// approved in Safari comes back to: the sheet waits, and is shown once at the activation.
    func testASheetAskedForWhileTheAppIsNotActiveWaitsForIt() async {
        let stage = Stage()
        stage.web.activated()
        XCTAssertEqual(stage.sheets.count, 0, "an activation with nothing waiting opened a sheet")

        stage.active = false
        stage.open("guest")
        stage.web.activated()
        await settle()
        XCTAssertEqual(stage.sheets.count, 0, "a sheet was begun while the app was not active")
        XCTAssertEqual(stage.dismissed, [])

        stage.active = true
        stage.web.activated()
        stage.web.activated()
        XCTAssertEqual(stage.urls, ["guest"])
        XCTAssertEqual(stage.sheets.map(\.began), [1])
        stage.sheets[0].ended(.dismissed)
        await settle()
        XCTAssertEqual(stage.dismissed, ["guest"])
    }

    /// A sheet the system would not take, by its start or by its completion, is nobody declining:
    /// it is tried once more, then waits for the next activation.
    func testASheetTheSystemRefusesIsNotADismissal() async {
        for byCompletion in [false, true] {
            let stage = Stage()
            stage.takes = byCompletion
            stage.open("guest")
            if byCompletion { stage.sheets[0].ended(.refused) }
            stage.takes = false
            await settle()
            XCTAssertEqual(stage.sheets.count, 2, "refused while active, it was not tried once more (completion: \(byCompletion))")
            await settle()
            XCTAssertEqual(stage.sheets.count, 2, "a system that keeps refusing was asked without end")
            XCTAssertEqual(stage.dismissed, [], "a refusal was taken for the person closing the sheet")

            stage.takes = true
            stage.web.activated()
            XCTAssertEqual(stage.sheets.count, 3)
            XCTAssertEqual(stage.urls, ["guest", "guest", "guest"])
            stage.sheets[2].ended(.dismissed)
            await settle()
            XCTAssertEqual(stage.dismissed, ["guest"])
        }
    }

    /// Refused for good, a sheet is still nobody declining: it waits for the app to close it.
    func testASheetRefusedTwiceStaysTheAppsToClose() async {
        let stage = Stage()
        stage.takes = false
        stage.open("login")
        await settle()
        XCTAssertEqual(stage.sheets.count, 2)
        stage.web.activated()
        stage.web.activated()
        await settle()
        XCTAssertEqual(stage.sheets.count, 4, "an activation did not show the sheet that was waiting")
        XCTAssertEqual(stage.dismissed, [], "a refusal was taken for the person closing the sheet")
        stage.web.close()
        stage.web.activated()
        await settle()
        XCTAssertEqual(stage.sheets.count, 4)
        XCTAssertEqual(stage.dismissed, [])
    }

    /// What the system's own completion says: only the person's close is a dismissal.
    func testOnlyAClosedSessionIsADismissal() {
        func error(_ code: ASWebAuthenticationSessionError.Code) -> any Error { ASWebAuthenticationSessionError(code) }
        XCTAssertEqual(WebAuth.ending(nil), .dismissed)
        XCTAssertEqual(WebAuth.ending(error(.canceledLogin)), .dismissed)
        XCTAssertEqual(WebAuth.ending(error(.presentationContextNotProvided)), .refused)
        XCTAssertEqual(WebAuth.ending(error(.presentationContextInvalid)), .refused)
        XCTAssertEqual(WebAuth.ending(URLError(.cancelled)), .refused)
    }

    /// Closed by the app, a sheet still waiting is never shown.
    func testAWaitingSheetTheAppClosesIsNotShown() async {
        let stage = Stage()
        stage.active = false
        stage.open("guest")
        stage.web.close()
        stage.active = true
        stage.web.activated()
        await settle()
        XCTAssertEqual(stage.sheets.count, 0)

        // Asked for again by hand, it is begun, and a refusal is tried once more afresh.
        stage.takes = false
        stage.open("guest")
        await settle()
        XCTAssertEqual(stage.sheets.count, 2)
        stage.open("guest")
        await settle()
        XCTAssertEqual(stage.sheets.count, 4)
        XCTAssertEqual(stage.dismissed, [])
    }
}
