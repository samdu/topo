import Foundation
import SwiftUI
import TopoAuth
import TopoTools
import UIKit
import XCTest

@testable import Topo

/// A GitHub that answers each step only when the test lets it, so a test can act while a flow is
/// held in the poll or in `/user`.
private final class HeldGitHub: GitHubConnecting, @unchecked Sendable {
    enum Step { case token, login }

    private let lock = NSLock()
    private var waiting: [Step: CheckedContinuation<Void, Never>] = [:]
    private var arrived: [Step: [CheckedContinuation<Void, Never>]] = [:]
    private var reached: Set<Step> = []
    private(set) var starts = 0

    let code = GitHubDeviceFlow.Code(userCode: "ABCD-1234", verificationURL: URL(string: "https://github.com/login/device")!,
                                     deviceCode: "dev", interval: 5, expiresIn: 900, issued: Date())

    func start() async throws -> GitHubDeviceFlow.Code {
        lock.withLock { starts += 1 }
        return code
    }

    func token(for code: GitHubDeviceFlow.Code) async throws -> String {
        await hold(.token)
        return "gho_token"
    }

    func login(token: String) async throws -> String {
        await hold(.login)
        return "samdu"
    }

    private func hold(_ step: Step) async {
        await withCheckedContinuation { continuation in
            let arrivals = lock.withLock {
                waiting[step] = continuation
                reached.insert(step)
                return arrived.removeValue(forKey: step) ?? []
            }
            arrivals.forEach { $0.resume() }
        }
    }

    /// Returns once a flow is held at `step`.
    func reach(_ step: Step) async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock {
                if reached.contains(step) { return true }
                arrived[step, default: []].append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    func release(_ step: Step) {
        lock.withLock { waiting.removeValue(forKey: step) }?.resume()
    }
}

@MainActor
private final class RecordingBrowser: Browser {
    var opened: [URL] = []
    var closes = 0
    func open(_ url: URL) { opened.append(url) }
    func close() { closes += 1 }
}

@MainActor
final class ConnectionsTests: XCTestCase {
    private var store: InMemoryConnectionStore!
    private var github: HeldGitHub!
    private var browser: RecordingBrowser!
    private var copied: [String] = []

    override func setUp() async throws {
        store = InMemoryConnectionStore()
        github = HeldGitHub()
        browser = RecordingBrowser()
        copied = []
    }

    private func connections() -> Connections {
        Connections(store: store, flow: github, copy: { [weak self] in self?.copied.append($0) }, browser: browser, leftBehind: .isolated())
    }

    /// Lets the main actor run what the flow queued after a release.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// A connect shows the code and polls, and copies nothing and opens nothing: the sheet would
    /// come up over a code the person has not seen. The sign's tap copies it and opens GitHub's
    /// page, and the flow saves the login once GitHub answers.
    func testAConnectShowsTheCodeAndOnlyTheTapCopiesItAndOpensGitHub() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        XCTAssertEqual(connections.github, .waiting(github.code))
        XCTAssertEqual(copied, [], "the code was copied before the tap")
        XCTAssertEqual(browser.opened, [], "GitHub's page opened before the code was copied")
        XCTAssertFalse(connections.codeCopied)

        connections.copyCodeAndOpenGitHub()
        XCTAssertEqual(copied, ["ABCD-1234"], "the tap copies at once, ahead of the page")
        XCTAssertTrue(connections.codeCopied)
        await settle()
        XCTAssertEqual(browser.opened, [github.code.verificationURL])

        github.release(.token)
        await github.reach(.login)
        github.release(.login)
        await settle()
        XCTAssertEqual(connections.github, .connected(login: "samdu"))
        XCTAssertEqual(try store.load(.github), Connection(token: "gho_token", account: "samdu"))
        XCTAssertEqual(browser.closes, 1, "the sheet closes once GitHub has answered")
        XCTAssertFalse(connections.codeCopied)
    }

    /// The page waits for the confirmation, and opens then only for the connect that is still
    /// waiting on that code: a Cancel or a second Connect during it opens nothing.
    func testThePageOpensAfterTheConfirmationAndNotAfterCancelOrASecondConnect() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        connections.copyCodeAndOpenGitHub(after: .milliseconds(200))
        await settle()
        XCTAssertEqual(browser.opened, [], "the page opened over the confirmation")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(browser.opened, [github.code.verificationURL])

        connections.copyCodeAndOpenGitHub(after: .milliseconds(200))
        connections.cancelGitHub()
        XCTAssertFalse(connections.codeCopied, "a Cancel left the code said to be copied")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(browser.opened.count, 1, "a cancelled connect opened GitHub's page")

        connections.connectGitHub()
        await settle()
        connections.copyCodeAndOpenGitHub(after: .milliseconds(200))
        connections.connectGitHub()
        XCTAssertFalse(connections.codeCopied, "a second Connect inherited the first one's copy")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(browser.opened.count, 1, "a superseded connect opened GitHub's page")
        github.release(.token)
    }

    /// A sign-out (`forget()`) or GitHub's approval during the confirmation opens nothing: the
    /// page waits only for the connect still waiting on the code that was copied.
    func testThePageOpensNotAfterASignOutOrAnApprovalDuringTheConfirmation() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        connections.copyCodeAndOpenGitHub(after: .milliseconds(200))
        connections.forget()
        XCTAssertFalse(connections.codeCopied, "a sign-out left the code said to be copied")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(browser.opened, [], "GitHub's page opened after a sign-out")

        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        connections.copyCodeAndOpenGitHub(after: .milliseconds(300))
        github.release(.token)
        await github.reach(.login)
        XCTAssertEqual(connections.github, .finishing)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(browser.opened, [], "GitHub's page opened after GitHub had approved")
        github.release(.login)
        await settle()
        XCTAssertEqual(connections.github, .connected(login: "samdu"))
        XCTAssertFalse(connections.codeCopied)
    }

    /// The sign hands its tap the look's pause: the compiled 0.9 seconds, or a document's.
    func testTheSignsTapWaitsTheLooksPause() {
        XCTAssertEqual(GitHubCodeSign.pause(Look().settings), .milliseconds(900))
        let slow = LookDocument.read(#"{"settings": {"copiedPause": 1.5}}"#).look
        XCTAssertEqual(GitHubCodeSign.pause(slow.settings), .milliseconds(1500))
    }

    /// With no code shown, the tap does nothing; and after the person closed the sheet, the tap
    /// copies again and opens again.
    func testTheTapNeedsACodeAndCanBeTakenAgain() async throws {
        let connections = connections()
        connections.copyCodeAndOpenGitHub()
        await settle()
        XCTAssertEqual(copied, [])
        XCTAssertEqual(browser.opened, [])

        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        connections.copyCodeAndOpenGitHub()
        await settle()
        connections.copyCodeAndOpenGitHub()
        await settle()
        XCTAssertEqual(copied, ["ABCD-1234", "ABCD-1234"])
        XCTAssertEqual(browser.opened, [github.code.verificationURL, github.code.verificationURL])
        github.release(.token)
    }

    func testAConnectionInTheStoreIsShownAtLaunch() throws {
        try store.save(Connection(token: "t", account: "someone"), for: .github)
        XCTAssertEqual(connections().github, .connected(login: "someone"))
    }

    func testATokenAfterCancelIsDropped() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        connections.cancelGitHub()
        github.release(.token)
        await settle()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github))
    }

    func testATokenAfterDisconnectIsDropped() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        connections.disconnectGitHub()
        github.release(.token)
        await settle()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github))
    }

    func testATokenAfterForgetIsDropped() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        connections.forget()
        github.release(.token)
        await settle()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github))
    }

    /// The last wait before the save is GitHub naming the user: a forget while it is out saves
    /// nothing when it comes back.
    func testALoginAfterForgetIsDropped() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        github.release(.token)
        await github.reach(.login)
        connections.forget()
        github.release(.login)
        await settle()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github))
    }

    func testASecondConnectDropsTheFirst() async throws {
        let first = HeldGitHub()
        let second = HeldGitHub()
        final class Switch: GitHubConnecting, @unchecked Sendable {
            let flows: [HeldGitHub]
            private let counter = NSLock()
            private var n = 0
            init(_ flows: [HeldGitHub]) { self.flows = flows }
            private func next() -> HeldGitHub { counter.withLock { defer { n += 1 }; return flows[min(n, flows.count - 1)] } }
            private var current: HeldGitHub { counter.withLock { flows[max(0, min(n - 1, flows.count - 1))] } }
            func start() async throws -> GitHubDeviceFlow.Code { try await next().start() }
            func token(for code: GitHubDeviceFlow.Code) async throws -> String {
                // The flow started last is the one that polls.
                try await current.token(for: code)
            }
            func login(token: String) async throws -> String { try await current.login(token: token) }
        }
        let connections = Connections(store: store, flow: Switch([first, second]), copy: { _ in }, browser: browser, leftBehind: .isolated())
        connections.connectGitHub()
        await first.reach(.token)
        connections.connectGitHub()
        await second.reach(.token)
        first.release(.token)
        await settle()
        XCTAssertNil(try store.load(.github), "the first flow's token lands after the second connect, and is dropped")
        XCTAssertEqual(connections.github, .waiting(second.code))
        second.release(.token)
        await second.reach(.login)
        second.release(.login)
        await settle()
        XCTAssertEqual(connections.github, .connected(login: "samdu"))
    }

    func testDisconnectForgetsTheToken() throws {
        try store.save(Connection(token: "t", account: "a"), for: .github)
        let connections = connections()
        connections.disconnectGitHub()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github))
    }
}

extension ConnectionsLeftBehind {
    /// One kept in a defaults suite of its own, so no test reads another's.
    static func isolated(installed: Bool = true) -> ConnectionsLeftBehind {
        let leftBehind = ConnectionsLeftBehind(defaults: UserDefaults(suiteName: "topo-tests-\(UUID().uuidString)")!)
        leftBehind.installed = installed
        return leftBehind
    }
}

/// A keychain holding one GitHub connection, whose clears the test refuses or lets through.
private final class StubbornStore: ConnectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Connection?
    private var refusing = true
    init(_ held: Connection) { self.held = held }
    struct Refused: Error {}
    var refuses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    func load(_ service: ConnectionService) throws -> Connection? { lock.withLock { service == .github ? held : nil } }
    func save(_ connection: Connection, for service: ConnectionService) throws { lock.withLock { held = connection } }
    func clear(_ service: ConnectionService) throws {
        try lock.withLock {
            if refusing { throw Refused() }
            held = nil
        }
    }
}

/// A keychain whose clear of the control secrets the test refuses or lets through.
private final class Refusing: @unchecked Sendable {
    private let lock = NSLock()
    private var refusing = true
    struct Refused: Error {}
    var refuses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }
    func clear() throws { if refuses { throw Refused() } }
}

@MainActor
final class ConnectionsLeftBehindTests: XCTestCase {
    /// A clear the keychain refused at a sign-out is kept past it: whoever signs in next is handed
    /// none of the token the earlier login connected, and a launch whose clear goes through leaves
    /// nothing to hand out.
    func testAClearRefusedAtASignOutHandsTheNextLoginNothing() async {
        let leftBehind = ConnectionsLeftBehind.isolated()
        let store = StubbornStore(Connection(token: "gho_first", account: "first"))
        let connections = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                      leftBehind: leftBehind)
        connections.forget()
        XCTAssertNotNil(leftBehind.words)
        let tool = GitHubTool(store: store, leftBehind: leftBehind)
        for call in [[], ["token"], ["credential"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.failed, "\(call)")
            XCTAssertFalse(reply.text.contains("gho_first"), "\(call): \(reply.text)")
            XCTAssertFalse(reply.text.contains("connected as first"), "\(call): \(reply.text)")
        }

        store.refuses = false
        let relaunched = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                     leftBehind: leftBehind)
        XCTAssertNil(leftBehind.words, "the launch tried the clear again")
        XCTAssertEqual(relaunched.github, .disconnected)
        let after = await tool.run(["token"])
        XCTAssertEqual(after.text, GitHubTool.notConnected)
    }

    /// A reinstall after a clear the keychain refused: the defaults and their mark are gone, the
    /// keychain item is not. The first launch of the install clears it before anything reads it,
    /// and a clear that fails again is kept as before.
    func testTheFirstLaunchOfAnInstallClearsAnEarlierInstallsTokens() async {
        let store = StubbornStore(Connection(token: "gho_first", account: "first"))
        store.refuses = false
        let fresh = ConnectionsLeftBehind.isolated(installed: false)
        let connections = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                      leftBehind: fresh)
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertTrue(fresh.installed)
        let reply = await GitHubTool(store: store, leftBehind: fresh).run(["token"])
        XCTAssertEqual(reply.text, GitHubTool.notConnected)

        let stubborn = StubbornStore(Connection(token: "gho_first", account: "first"))
        let again = ConnectionsLeftBehind.isolated(installed: false)
        _ = Connections(store: stubborn, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(), leftBehind: again)
        XCTAssertNotNil(again.words)
        let refused = await GitHubTool(store: stubborn, leftBehind: again).run(["token"])
        XCTAssertEqual(refused.status, ToolReply.failed)
        XCTAssertFalse(refused.text.contains("gho_first"))
    }

    /// While the clear still fails, a connect is refused rather than saved beside the old token.
    func testAConnectWhileTheClearStillFailsIsRefused() {
        let leftBehind = ConnectionsLeftBehind.isolated()
        leftBehind.words = "the GitHub token could not be removed from this phone's keychain: -25308"
        let github = HeldGitHub()
        let connections = Connections(store: StubbornStore(Connection(token: "gho_first", account: "first")),
                                      flow: github, copy: { _ in }, browser: RecordingBrowser(), leftBehind: leftBehind)
        connections.connectGitHub()
        guard case let .failed(words) = connections.github else { return XCTFail("\(connections.github)") }
        XCTAssertTrue(words.contains("could not be removed"), words)
    }

    /// A clear of the control secrets the keychain refused at a sign-out is kept and said on the
    /// sign-in screen, apart from the connections: the next launch tries it again alone, and a
    /// GitHub token the next login connected meanwhile survives it.
    func testAControlSecretsClearRefusedIsKeptApartAndTriedAgainAlone() {
        let leftBehind = ConnectionsLeftBehind.isolated()
        let refusing = Refusing()
        let store = InMemoryConnectionStore()
        let connections = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                      leftBehind: leftBehind, clearControlSecrets: { try refusing.clear() })
        connections.forget()
        XCTAssertNotNil(leftBehind.controlSecrets)
        XCTAssertNil(leftBehind.words, "a refusal of the control secrets refused the connections")
        XCTAssertTrue(connections.unforgotten?.contains("controls' secrets") == true, "\(String(describing: connections.unforgotten))")

        try? store.save(Connection(token: "gho_next", account: "next"), for: .github)
        refusing.refuses = false
        let relaunched = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                     leftBehind: leftBehind, clearControlSecrets: { try refusing.clear() })
        XCTAssertNil(leftBehind.controlSecrets, "the launch tried the clear again")
        XCTAssertNil(relaunched.unforgotten)
        XCTAssertEqual(relaunched.github, .connected(login: "next"), "the retry took the next login's token")
    }

    /// A Disconnect made signed in, which retries a clear of the connections refused before, takes
    /// the connections alone: the mind's control secrets survive it.
    func testADisconnectRetryLeavesTheControlSecrets() throws {
        let secrets = ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)")
        defer { try? secrets.clearAll() }
        let leftBehind = ConnectionsLeftBehind.isolated()
        let store = StubbornStore(Connection(token: "gho_first", account: "first"))
        let connections = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                      leftBehind: leftBehind, clearControlSecrets: { try secrets.clearAll() })
        connections.forget()
        XCTAssertNotNil(leftBehind.words)
        try secrets.set("tok", name: "ha")
        connections.disconnectGitHub()
        XCTAssertEqual(try secrets.names(), ["ha"], "a Disconnect took the control secrets")
        XCTAssertNotNil(connections.unforgotten)
        XCTAssertFalse(connections.unforgotten?.contains("controls' secrets") == true)
        store.refuses = false
        connections.disconnectGitHub()
        XCTAssertNil(leftBehind.words)
        XCTAssertNil(connections.unforgotten, "the words outlived the clear that went through")
        XCTAssertEqual(try secrets.names(), ["ha"])
    }

    /// The first launch of an install clears the control secrets too, and an empty keychain is a
    /// clear that went through, not one left behind.
    func testTheFirstLaunchOfAnInstallClearsTheControlSecrets() throws {
        let secrets = ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)")
        defer { try? secrets.clearAll() }
        let fresh = ConnectionsLeftBehind.isolated(installed: false)
        let empty = Connections(store: InMemoryConnectionStore(), flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                leftBehind: fresh, clearControlSecrets: { try secrets.clearAll() })
        XCTAssertNil(fresh.controlSecrets)
        XCTAssertNil(empty.unforgotten)

        try secrets.set("earlier", name: "ha")
        let again = ConnectionsLeftBehind.isolated(installed: false)
        _ = Connections(store: InMemoryConnectionStore(), flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                        leftBehind: again, clearControlSecrets: { try secrets.clearAll() })
        XCTAssertEqual(try secrets.names(), [], "an earlier install's control secret outlived the first launch")
    }

    /// A Disconnect the keychain refused leaves the GitHub row failed with Disconnect still
    /// offered, and Disconnect tries the clear again: once the keychain lets it, the token is gone.
    func testAFailedClearKeepsDisconnectWhichTriesItAgain() throws {
        XCTAssertEqual(ConnectionsView.githubActions(.failed("x")), [.tryAgain, .disconnect])
        XCTAssertEqual(ConnectionsView.githubActions(.waiting(HeldGitHub().code)), [.openGitHub, .cancel])
        XCTAssertEqual(ConnectionsView.githubActions(.connected(login: "samdu")), [.revoke, .disconnect])
        XCTAssertFalse(ConnectionsView.githubActions(.disconnected).contains(.disconnect))

        let store = StubbornStore(Connection(token: "gho_first", account: "first"))
        store.refuses = false
        let connections = Connections(store: store, flow: HeldGitHub(), copy: { _ in }, browser: RecordingBrowser(),
                                      leftBehind: .isolated())
        XCTAssertEqual(connections.github, .connected(login: "first"))
        store.refuses = true
        connections.disconnectGitHub()
        guard case .failed = connections.github else { return XCTFail("not failed: \(connections.github)") }
        XCTAssertNotNil(try store.load(.github))
        store.refuses = false
        connections.disconnectGitHub()
        XCTAssertEqual(connections.github, .disconnected)
        XCTAssertNil(try store.load(.github), "the retried Disconnect left the token")
    }
}

/// A keychain that refuses every read, or every clear.
private final class RefusingStore: ConnectionStore, @unchecked Sendable {
    let refusesReads: Bool
    init(refusesReads: Bool) { self.refusesReads = refusesReads }
    struct Refused: Error {}
    func load(_ service: ConnectionService) throws -> Connection? {
        if refusesReads { throw Refused() }
        return Connection(token: "t", account: "someone")
    }
    func save(_ connection: Connection, for service: ConnectionService) throws {}
    func clear(_ service: ConnectionService) throws { throw Refused() }
}

@MainActor
final class ConnectionsKeychainTests: XCTestCase {
    /// A keychain that cannot be read is said, never shown as not connected.
    func testAnUnreadableKeychainIsSaidAtLaunch() {
        let connections = Connections(store: RefusingStore(refusesReads: true), flow: HeldGitHub(),
                                      copy: { _ in }, browser: RecordingBrowser(), leftBehind: .isolated())
        guard case let .failed(words) = connections.github else { return XCTFail("\(connections.github)") }
        XCTAssertTrue(words.contains("could not be read"), words)
    }

    /// A clear the keychain refuses is said on the row, not shown as disconnected.
    func testAForgetTheKeychainRefusesIsSaid() {
        let connections = Connections(store: RefusingStore(refusesReads: false), flow: HeldGitHub(),
                                      copy: { _ in }, browser: RecordingBrowser(), leftBehind: .isolated())
        XCTAssertEqual(connections.github, .connected(login: "someone"))
        connections.forget()
        guard case let .failed(words) = connections.github else { return XCTFail("\(connections.github)") }
        XCTAssertTrue(words.contains("could not be removed"), words)
        XCTAssertEqual(connections.unforgotten.map { $0.hasPrefix("the connections' tokens could not be removed") }, true,
                       "what the sign-in screen says after the sign-out")
    }
}

final class GitHubToolTests: XCTestCase {
    func testNotConnectedSaysWhereToConnect() async {
        let tool = GitHubTool(store: InMemoryConnectionStore(), leftBehind: .isolated())
        for call in [[], ["token"], ["credential"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.failed, "\(call)")
            XCTAssertEqual(reply.text, GitHubTool.notConnected)
        }
    }

    func testConnectedAnswersEachForm() async {
        let store = InMemoryConnectionStore([.github: Connection(token: "gho_x", account: "samdu")])
        let tool = GitHubTool(store: store, leftBehind: .isolated())
        let status = await tool.run([])
        XCTAssertEqual(status, .ok("connected as samdu\n"))
        XCTAssertFalse(status.text.contains("gho_x"), "the status never carries the token")
        let token = await tool.run(["token"])
        XCTAssertEqual(token, .ok("gho_x\n"))
        let credential = await tool.run(["credential"])
        XCTAssertEqual(credential, .ok("username=samdu\npassword=gho_x\n"))
    }

    func testAnythingElseIsUsage() async {
        let tool = GitHubTool(store: InMemoryConnectionStore(), leftBehind: .isolated())
        for call in [["login"], ["token", "extra"], ["--token"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(call)")
        }
    }

    /// The token is read on every call, so a disconnect reaches the guest at its next one.
    func testDisconnectIsHonouredAtTheNextCall() async throws {
        let store = InMemoryConnectionStore([.github: Connection(token: "gho_x", account: "samdu")])
        let tool = GitHubTool(store: store, leftBehind: .isolated())
        let before = await tool.run(["token"])
        XCTAssertEqual(before.status, ToolReply.ok)
        try store.clear(.github)
        let after = await tool.run(["token"])
        XCTAssertEqual(after.status, ToolReply.failed)
        XCTAssertFalse(after.text.contains("gho_x"))
    }
}

/// The Connections screen in its four standing states, drawn under the compiled look and kept as
/// attachments: what the screen says is read off the pictures, since `simctl` cannot tap through
/// Settings to it. Each state is checked to be the one drawn, and the three pictures to be drawn
/// (more than a background's worth of colours) and to differ from one another.
@MainActor
final class ConnectionsScreenshots: XCTestCase {
    func testTheScreenInEachState() async throws {
        let store = InMemoryConnectionStore()
        let github = HeldGitHub()
        let connections = Connections(store: store, flow: github, copy: { _ in }, browser: RecordingBrowser(), leftBehind: .isolated())
        XCTAssertEqual(connections.github, .disconnected)
        let disconnected = try attach(connections, "connections-disconnected")

        connections.connectGitHub()
        await github.reach(.token)
        for _ in 0..<20 { await Task.yield() }
        guard case .waiting = connections.github else { return XCTFail("not waiting: \(connections.github)") }
        let waiting = try attach(connections, "connections-waiting")
        connections.copyCodeAndOpenGitHub()
        let copied = try attach(connections, "connections-copied")

        connections.cancelGitHub()
        try store.save(Connection(token: "gho_x", account: "samdu"), for: .github)
        let reopened = Connections(store: store, flow: github, copy: { _ in }, browser: RecordingBrowser(), leftBehind: .isolated())
        guard case .connected = reopened.github else { return XCTFail("not connected: \(reopened.github)") }
        let connected = try attach(reopened, "connections-connected")
        github.release(.token)

        for (name, image) in [("disconnected", disconnected), ("waiting", waiting), ("copied", copied), ("connected", connected)] {
            XCTAssertGreaterThan(try colours(image), 8, "\(name) is drawn as a blank screen")
        }
        let pictures = try [disconnected, waiting, copied, connected].map { try XCTUnwrap($0.pngData()) }
        XCTAssertEqual(Set(pictures).count, 4, "two states are drawn the same")
    }

    /// The sign carries the code from the first frame drawn: two codes draw two different
    /// pictures, which they would not if the sign were missing, or if the first frame were him
    /// still taking it up.
    func testTheSignHoldsTheCodeFromTheFirstFrame() throws {
        let size = CGSize(width: 390, height: 360)
        func sign(_ code: String) throws -> Data {
            let image = try LookStage.image(GitHubCodeSign(code: code, copied: false, tapped: { _ in })
                .environment(Mascot()), look: Look(), size: size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "sign-\(code)"
            attachment.lifetime = .keepAlways
            add(attachment)
            return try XCTUnwrap(image.pngData())
        }
        XCTAssertNotEqual(try sign("ABCD-1234"), try sign("WXYZ-9876"), "the sign does not carry the code")
    }

    /// The largest sign and line a look document can set fit a 320-point-wide page and leave the
    /// list above them room on a 667-point one; a scale past the largest is not taken.
    func testTheLargestSignFitsTheNarrowestPage() {
        let rejected = LookDocument.read(#"{"settings": {"signScale": 3, "signFont": {"size": 400}}}"#).look
        XCTAssertEqual(rejected.settings.signScale, Look().settings.signScale)
        let largest = LookDocument.read(#"{"settings": {"signScale": 2, "signSpacing": 32, "signFont": {"size": 400}}}"#).look
        XCTAssertEqual(largest.settings.signScale, 2)
        for copied in [false, true] {
            let host = UIHostingController(rootView: GitHubCodeSign(code: "ABCD-1234", copied: copied, tapped: { _ in })
                .environment(Mascot()).environment(\.look, largest))
            let fitted = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.infinity))
            XCTAssertLessThanOrEqual(fitted.width, 320, "copied \(copied): the sign is wider than the page")
            XCTAssertLessThanOrEqual(fitted.height, 667 * 0.7, "copied \(copied): the sign leaves the list no room")
        }
    }

    private func attach(_ connections: Connections, _ name: String) throws -> UIImage {
        let image = try LookStage.image(ConnectionsView().environment(connections).environment(Mascot()), look: Look())
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    /// How many distinct colours the picture has, up to a few hundred.
    private func colours(_ image: UIImage) throws -> Int {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for pixel in pixels where seen.count < 300 { seen.insert(pixel) }
        return seen.count
    }
}
