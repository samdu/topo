import Foundation
import TopoAuth
import XCTest
@testable import Topo

/// The sign-in's browser sheet (`WebAuth`): only the person closing the sheet that is up is a
/// dismissal. One the app closed, or replaced with the next authorization, tells nobody, however
/// late its own ending is reported.
@MainActor
final class WebAuthTests: XCTestCase {
    private final class Sheet: WebAuth.Sheet {
        let gone: @Sendable () -> Void
        var began = 0, cancelled = 0
        init(gone: @escaping @Sendable () -> Void) { self.gone = gone }
        func begin() { began += 1 }
        func cancel() { cancelled += 1 }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testOnlyTheSheetThatIsUpReportsItsDismissal() async {
        let web = WebAuth()
        var sheets: [Sheet] = []
        web.makeSheet = { _, gone in
            let sheet = Sheet(gone: gone)
            sheets.append(sheet)
            return sheet
        }
        var dismissed: [String] = []
        web.open(URL(string: "https://example.com/login")!) { dismissed.append("login") }
        // The login landed: the sign-in opens the guest's authorization in the login's place.
        web.open(URL(string: "https://example.com/guest")!) { dismissed.append("guest") }
        XCTAssertEqual(sheets.map(\.began), [1, 1])
        XCTAssertEqual(sheets.map(\.cancelled), [1, 0], "the replaced sheet was left up")
        // The replaced sheet reports its ending late.
        sheets[0].gone()
        await settle()
        XCTAssertEqual(dismissed, [], "a sheet the app replaced was taken for the person closing it")

        // The app closes the second on a finished sign-in; its ending is nobody's dismissal either.
        web.close()
        sheets[1].gone()
        await settle()
        XCTAssertEqual(dismissed, [])
        XCTAssertEqual(sheets[1].cancelled, 1)

        // A sheet the person closes is reported, once.
        web.open(URL(string: "https://example.com/again")!) { dismissed.append("again") }
        sheets[2].gone()
        sheets[2].gone()
        await settle()
        XCTAssertEqual(dismissed, ["again"])
    }

    /// The guest token's row in Diagnostics says whether it is held and for how long, never it.
    func testTheGuestTokensRowSaysWhetherItIsHeld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func tokens(expiring: TimeInterval) -> Tokens {
            Tokens(accessToken: "sk-ant-oat01-secret", refreshToken: "", expiresAt: now.addingTimeInterval(expiring), scopes: ["user:inference"])
        }
        XCTAssertEqual(GuestTokenSummary.of(now: now) { nil }, "none held; Claude Code runs on the ordinary token")
        XCTAssertEqual(GuestTokenSummary.of(now: now) { tokens(expiring: 364.5 * 86_400) }, "held, 364 days left")
        XCTAssertEqual(GuestTokenSummary.of(now: now) { tokens(expiring: -1) }, "held, expired")
        XCTAssertTrue(GuestTokenSummary.of(now: now) { throw CocoaError(.fileReadNoPermission) }.hasPrefix("unreadable: "))
        XCTAssertFalse(GuestTokenSummary.of(now: now) { tokens(expiring: 86_400) }.contains("secret"))
    }
}
