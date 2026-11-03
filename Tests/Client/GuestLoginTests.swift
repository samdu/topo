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

    /// The guest's files are out of `Documents`, which Finder's file sharing shows: the standard
    /// place is Application Support.
    func testTheGuestsFilesAreOutOfDocuments() {
        for url in [GuestResident.homeDirectory, GuestResident.sessionFile.url, GuestResident.cutFile.url, GuestResident.ledgerFile] {
            XCTAssertFalse(url.path.hasPrefix(URL.documentsDirectory.path), url.path)
            XCTAssertTrue(url.path.hasPrefix(URL.applicationSupportDirectory.path), url.path)
        }
    }

    /// An install from before keeps the home (with a login and a transcript), the session, the cut
    /// and the ledger in `Documents`: each is moved, its bytes with it, and nothing stays behind for
    /// file sharing to show. A file in neither place is answered with the new one.
    func testEverythingInDocumentsIsMovedWithItsBytes() throws {
        let (files, root) = try placedFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = ["home/.claude/.credentials.json": "login", "home/.claude/projects/p/s.jsonl": "transcript",
                    ".guest-session": "session", ".guest-cut.json": "cut", ".guest-bridge.json": "ledger"]
        for (path, bytes) in kept { try write(bytes, to: files.old.appendingPathComponent(path)) }

        let home = files.place("home", isDirectory: true)
        XCTAssertEqual(home.path, files.new.appendingPathComponent("home").path)
        let placed = [".guest-session", ".guest-cut.json", ".guest-bridge.json"].map { files.place($0) }
        XCTAssertEqual(placed.map(\.path), [".guest-session", ".guest-cut.json", ".guest-bridge.json"].map { files.new.appendingPathComponent($0).path })
        for (path, bytes) in kept {
            XCTAssertEqual(try Data(contentsOf: files.new.appendingPathComponent(path)), Data(bytes.utf8), path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.old.path), [])
        XCTAssertEqual(files.place(".nothing").path, files.new.appendingPathComponent(".nothing").path)
    }

    /// Each file is placed on its own: a session whose move is refused stays in `Documents` with
    /// its bytes, and the cut, moved, is read where it went, since the session is handed it by
    /// path (`GuestResident.cutFile`) rather than finding it beside the session file.
    func testARefusedSessionMoveLeavesTheCutWhereItWent() throws {
        let (placed, root) = try placedFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = placed
        files.files = RefusingMoves(refusing: ".guest-session")
        try write("session", to: files.old.appendingPathComponent(".guest-session"))
        try write("cut", to: files.old.appendingPathComponent(".guest-cut.json"))

        let session = files.place(".guest-session")
        let cut = files.place(".guest-cut.json")
        XCTAssertEqual(session.path, files.old.appendingPathComponent(".guest-session").path)
        XCTAssertEqual(try Data(contentsOf: session), Data("session".utf8))
        XCTAssertEqual(cut.path, files.new.appendingPathComponent(".guest-cut.json").path)
        XCTAssertEqual(try Data(contentsOf: cut), Data("cut".utf8))
    }

    /// A sign-out takes away the credential wherever it rests, a copy left in `Documents`
    /// included, and does not say it is gone while either stands.
    func testSignOutRemovesEveryCopyOfTheCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credentials-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("old/.claude").path)
            try? FileManager.default.removeItem(at: root)
        }
        let new = root.appendingPathComponent("new/.claude/.credentials.json")
        let old = root.appendingPathComponent("old/.claude/.credentials.json")
        try write("login", to: new)
        try write("login", to: old)
        XCTAssertTrue(GuestLogin.removeCredentials([new, old]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        try write("login", to: new)
        try write("login", to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: old.deletingLastPathComponent().path)
        XCTAssertFalse(GuestLogin.removeCredentials([new, old]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(GuestLogin.credentialsFiles.first, GuestLogin.credentialsFile)
    }

    /// One in the new place is the one; a copy left in `Documents` is stale and is taken away.
    func testTheNewPlaceWinsAndTheOldCopyGoes() throws {
        let (files, root) = try placedFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: files.old.appendingPathComponent(".guest-session"))
        try FileManager.default.createDirectory(at: files.new, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: files.new.appendingPathComponent(".guest-session"))

        let session = files.place(".guest-session")
        XCTAssertEqual(try Data(contentsOf: session), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.old.appendingPathComponent(".guest-session").path))
    }

    /// A move that fails leaves the login where it is and answers that place, so the launch reads
    /// it there rather than an empty home that would sign the phone out.
    func testAFailedMoveKeepsTheOldPlace() throws {
        let (placed, root) = try placedFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = placed
        files.files = RefusingMoves()
        let credential = files.old.appendingPathComponent("home/.claude/.credentials.json")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("login".utf8).write(to: credential)

        XCTAssertEqual(files.place("home", isDirectory: true).path, files.old.appendingPathComponent("home").path)
        XCTAssertEqual(try Data(contentsOf: credential), Data("login".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.new.appendingPathComponent("home").path))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func placedFiles() throws -> (GuestFiles, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-files-\(UUID().uuidString)", isDirectory: true)
        let old = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        return (GuestFiles(old: old, new: root.appendingPathComponent("Library/Application Support", isDirectory: true)), root)
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

    /// Review focus 8: the placeholder key is given to a launch only on a phone using Topo
    /// without an account, and never to the login's own processes, whose status would then be
    /// the key's rather than the Claude login's.
    func testThePlaceholderKeyIsALaunchsOnlyWithoutAnAccount() throws {
        let defaults = UserDefaults(suiteName: "launch-\(UUID().uuidString)")!
        let cache = LoginCache(defaults: defaults)
        let local = LocalLogin(defaults: defaults)
        cache.save(ClaudeLoginStatus(loggedIn: true, authMethod: "claude.ai"))
        XCTAssertNil(try GuestResident.launchCredential(port: 4000, cache: cache, local: local)["ANTHROPIC_API_KEY"])
        local.set(true)
        cache.save(LocalLogin.status)
        let launch = try GuestResident.launchCredential(port: 4000, cache: cache, local: local)
        XCTAssertEqual(launch["ANTHROPIC_API_KEY"], OnDeviceModel.placeholderKey)
        XCTAssertEqual(launch["ANTHROPIC_SMALL_FAST_MODEL"], OnDeviceModel.id)
        XCTAssertEqual(launch["ANTHROPIC_BASE_URL"], APIProxy.baseURL(port: 4000))
    }

    /// Review focus 9: a process launched with the on-device model asks nothing else on the side,
    /// and one launched with a Claude model is told nothing of it.
    func testAnOnDeviceProcessAsksTheOnDeviceModelOnTheSideToo() {
        let told = GuestResident.modelEnvironment(OnDeviceModel.id)
        for variable in OnDeviceModel.modelVariables { XCTAssertEqual(told[variable], OnDeviceModel.id, variable) }
        XCTAssertNil(told["ANTHROPIC_API_KEY"], "the key is the login's, not the model's")
        XCTAssertEqual(GuestResident.modelEnvironment("sonnet"), [:])
        XCTAssertEqual(GuestResident.modelEnvironment(nil), [:])
    }

    /// Review focus 8, the login's side: with a login without an account standing, the login's
    /// own environment carries nothing of the on-device model's, so `auth status` reads the
    /// Claude login and not the placeholder key.
    func testTheLoginsEnvironmentCarriesNoPlaceholderUnderALocalLogin() {
        let local = LocalLogin.standard
        let was = local.isOn
        local.set(true)
        defer { local.set(was) }
        for browser in [false, true] {
            let environment = GuestLogin.environment(tools: ["TOPO_TOOLS_URL": "http://127.0.0.1:1"], browser: browser)
            XCTAssertNil(environment["ANTHROPIC_API_KEY"])
            XCTAssertFalse(environment.values.contains { $0.contains(OnDeviceModel.placeholderKey) || $0 == OnDeviceModel.id },
                           "\(environment)")
        }
    }

    /// Review focus 9 as the resident launches: the launcher the resident makes tells a process
    /// on the on-device model every side model's variable, and one on a Claude model none.
    func testTheResidentsLauncherToldTheModelsEnvironment() async throws {
        let launcher = GuestResident.launcher { ["ANTHROPIC_BASE_URL": "http://127.0.0.1:1"] }
        let onDevice = try await launcher.launchEnvironment(model: OnDeviceModel.id)
        for variable in OnDeviceModel.modelVariables { XCTAssertEqual(onDevice[variable], OnDeviceModel.id, variable) }
        XCTAssertEqual(onDevice["ANTHROPIC_BASE_URL"], "http://127.0.0.1:1")
        let sonnet = try await launcher.launchEnvironment(model: "sonnet")
        for variable in OnDeviceModel.modelVariables { XCTAssertNil(sonnet[variable], variable) }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URL] = []
        func add(_ url: URL) { lock.withLock { all.append(url) } }
        var urls: [URL] { lock.withLock { all } }
    }
}

/// A file manager whose moves fail, as one before the first unlock might: every move, or only
/// the move of the one name given.
private final class RefusingMoves: FileManager, @unchecked Sendable {
    let refusing: String?

    init(refusing: String? = nil) {
        self.refusing = refusing
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard refusing == nil || srcURL.lastPathComponent == refusing else {
            return try super.moveItem(at: srcURL, to: dstURL)
        }
        throw CocoaError(.fileWriteNoPermission)
    }
}
