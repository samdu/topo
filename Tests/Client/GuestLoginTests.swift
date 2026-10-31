import Foundation
import TopoAuth
import TopoProxy
import TopoTools
import XCTest

@testable import Topo

/// The app's half of Claude Code's login in the guest: what reaches the sign-in's sheet, what the
/// login's output and exit say, and where the credential it writes rests.
@MainActor
final class GuestLoginTests: XCTestCase {
    let authorize = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A65479%2Fcallback&state=s"
    let page = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s"

    /// `topo open-url` reaches the sheet only while a sign-in waits for its browser, and only with
    /// an https URL on Claude's own hosts: outside a sign-in the mind cannot put a page on the phone.
    func testOpenURLReachesOnlyAWaitingSignInAndOnlyClaudesHosts() async throws {
        let browser = LoginBrowser()
        let tool = OpenURLTool(browser: { url in await browser.offer(url) })
        let refused = await tool.run([authorize])
        XCTAssertEqual(refused.status, ToolReply.refused, "a URL opened with no sign-in waiting")

        let heard = Heard()
        let id = browser.open { heard.add($0) }
        let opened = await tool.run([authorize])
        XCTAssertEqual(opened.status, ToolReply.ok)
        XCTAssertEqual(heard.urls, [URL(string: authorize)!])

        for url in ["http://claude.com/cai/oauth/authorize", "https://example.com/", "https://claude.com.example.com/",
                    "https://user:pass@claude.com/", "https://claude.com:8443/", "topo://open", "file:///etc/passwd"] {
            let reply = await tool.run([url])
            XCTAssertEqual(reply.status, ToolReply.refused, url)
        }
        let none = await tool.run([])
        XCTAssertEqual(none.status, ToolReply.usage)
        let two = await tool.run([authorize, "more"])
        XCTAssertEqual(two.status, ToolReply.usage)
        XCTAssertEqual(heard.urls.count, 1, "a refused URL reached the sheet")

        browser.close(id)
        let after = await tool.run([authorize])
        XCTAssertEqual(after.status, ToolReply.refused, "a URL opened after the sign-in let go")
    }

    /// A second login's registration replaces the first, and the first's close does not undo it.
    func testAnOlderLoginsCloseLeavesTheNewerOneWaiting() async {
        let browser = LoginBrowser()
        let first = browser.open { _ in }
        let heard = Heard()
        _ = browser.open { heard.add($0) }
        browser.close(first)
        XCTAssertTrue(browser.offer(URL(string: authorize)!))
        XCTAssertEqual(heard.urls.count, 1)
    }

    /// The paste-page URL is the one whose redirect is Claude's hosted page; the loopback one, and
    /// anything that is not Claude's, is not.
    func testThePastePageIsTheURLRedirectingToClaudesCodePage() {
        XCTAssertEqual(GuestLogin.pastePage(in: "If the browser didn't open, visit: \(page)"), URL(string: page))
        XCTAssertEqual(GuestLogin.pastePage(in: page), URL(string: page))
        XCTAssertNil(GuestLogin.pastePage(in: authorize))
        XCTAssertNil(GuestLogin.pastePage(in: "Opening browser to sign in…"))
        XCTAssertNil(GuestLogin.pastePage(in: "visit https://example.com/?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"))
    }

    /// Exit 0 is signed in, exit 1 is what Claude Code said went wrong, and a login the app ended,
    /// or one ended any other way, is stopped.
    func testWhatALoginsExitSays() {
        let said = ["Opening browser to sign in…", "Login failed: Invalid state parameter", ""]
        XCTAssertEqual(GuestLogin.end(status: 0, ended: false, said: said), .succeeded)
        XCTAssertEqual(GuestLogin.end(status: 1, ended: false, said: said), .failed("Login failed: Invalid state parameter"))
        XCTAssertEqual(GuestLogin.end(status: 1, ended: false, said: ["something else"]), .failed("something else"))
        XCTAssertEqual(GuestLogin.end(status: 1, ended: false, said: []), .failed("Claude Code's sign-in failed."))
        XCTAssertEqual(GuestLogin.end(status: 143, ended: false, said: said), .stopped)
        XCTAssertEqual(GuestLogin.end(status: nil, ended: false, said: said), .stopped)
        XCTAssertEqual(GuestLogin.end(status: 0, ended: true, said: said), .stopped)
        XCTAssertEqual(GuestLogin.end(status: 1, ended: true, said: said), .stopped)
    }

    /// The login runs `claude auth login --claudeai` from the home, as the resident is started.
    func testTheLoginIsClaudeCodesOwnCommand() {
        XCTAssertEqual(GuestLogin.command(["auth", "login", "--claudeai"]),
                       ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", "/usr/local/bin/claude", "auth", "login", "--claudeai"])
    }

    /// The guest's home, where Claude Code keeps its Claude.ai credential, is excluded from
    /// backup, and it and its `.claude` are given the protection the keychain item had. The
    /// simulator keeps no protection class, so what is checked is what was asked for.
    func testTheHomeIsExcludedFromBackupAndProtected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("login-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var asked: [String: FileProtectionType] = [:]
        try GuestResident.makeHome(home) { attributes, path in
            asked[path] = attributes[.protectionKey] as? FileProtectionType
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        }
        XCTAssertEqual(try home.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for url in [home, home.appendingPathComponent(".claude", isDirectory: true)] {
            XCTAssertEqual(asked[url.path], .completeUntilFirstUserAuthentication, url.path)
        }
        // Made again over itself, as every launch does.
        try GuestResident.makeHome(home)
    }

    /// A launch with no login is refused before Claude Code is started, and the refusal says so.
    func testTheResidentIsNotLaunchedSignedOut() async throws {
        let cache = LoginCache.standard
        let kept = cache.status
        defer { if let kept { cache.save(kept) } else { cache.clear() } }
        cache.clear()
        do {
            try await ResidentConversation().ready()
            XCTFail("a signed-out phone readied the resident")
        } catch GuestBridgeError.notReady(let why) {
            XCTAssertEqual(why, "signed out")
        }
    }

    /// The launcher's own guard: every launch of the resident, whatever path started the guest,
    /// asks for its credential here, and a signed-out cache refuses it.
    func testTheLauncherRefusesALaunchWhileSignedOut() throws {
        let cache = LoginCache(defaults: UserDefaults(suiteName: "launch-\(UUID().uuidString)")!)
        XCTAssertThrowsError(try GuestResident.launchCredential(port: 4000, cache: cache)) { error in
            guard case GuestBridgeError.notReady("signed out") = error else { return XCTFail("\(error)") }
        }
        cache.save(ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai"))
        XCTAssertEqual(try GuestResident.launchCredential(port: 4000, cache: cache)["ANTHROPIC_BASE_URL"], APIProxy.baseURL(port: 4000))
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URL] = []
        func add(_ url: URL) { lock.withLock { all.append(url) } }
        var urls: [URL] { lock.withLock { all } }
    }
}
