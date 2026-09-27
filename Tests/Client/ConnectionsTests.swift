import Foundation
import TopoAuth
import TopoTools
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
        return "ghu_token"
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
        Connections(store: store, flow: github, copy: { [weak self] in self?.copied.append($0) }, browser: browser)
    }

    /// Lets the main actor run what the flow queued after a release.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testAConnectShowsAndCopiesTheCodeOpensGitHubAndSavesTheLogin() async throws {
        let connections = connections()
        connections.connectGitHub()
        await github.reach(.token)
        await settle()
        XCTAssertEqual(connections.github, .waiting(github.code))
        XCTAssertEqual(copied, ["ABCD-1234"])
        XCTAssertEqual(browser.opened, [github.code.verificationURL])
        github.release(.token)
        await github.reach(.login)
        github.release(.login)
        await settle()
        XCTAssertEqual(connections.github, .connected(login: "samdu"))
        XCTAssertEqual(try store.load(.github), Connection(token: "ghu_token", account: "samdu"))
        XCTAssertEqual(browser.closes, 1, "the sheet closes once GitHub has answered")
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
        let connections = Connections(store: store, flow: Switch([first, second]), copy: { _ in }, browser: browser)
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

final class GitHubToolTests: XCTestCase {
    func testNotConnectedSaysWhereToConnect() async {
        let tool = GitHubTool(store: InMemoryConnectionStore())
        for call in [[], ["token"], ["credential"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.failed, "\(call)")
            XCTAssertEqual(reply.text, GitHubTool.notConnected)
        }
    }

    func testConnectedAnswersEachForm() async {
        let store = InMemoryConnectionStore([.github: Connection(token: "ghu_x", account: "samdu")])
        let tool = GitHubTool(store: store)
        let status = await tool.run([])
        XCTAssertEqual(status, .ok("connected as samdu\n"))
        XCTAssertFalse(status.text.contains("ghu_x"), "the status never carries the token")
        let token = await tool.run(["token"])
        XCTAssertEqual(token, .ok("ghu_x\n"))
        let credential = await tool.run(["credential"])
        XCTAssertEqual(credential, .ok("username=samdu\npassword=ghu_x\n"))
    }

    func testAnythingElseIsUsage() async {
        let tool = GitHubTool(store: InMemoryConnectionStore())
        for call in [["login"], ["token", "extra"], ["--token"]] {
            let reply = await tool.run(call)
            XCTAssertEqual(reply.status, ToolReply.usage, "\(call)")
        }
    }

    /// The token is read on every call, so a disconnect reaches the guest at its next one.
    func testDisconnectIsHonouredAtTheNextCall() async throws {
        let store = InMemoryConnectionStore([.github: Connection(token: "ghu_x", account: "samdu")])
        let tool = GitHubTool(store: store)
        let before = await tool.run(["token"])
        XCTAssertEqual(before.status, ToolReply.ok)
        try store.clear(.github)
        let after = await tool.run(["token"])
        XCTAssertEqual(after.status, ToolReply.failed)
        XCTAssertFalse(after.text.contains("ghu_x"))
    }
}

/// The Connections screen in its three standing states, drawn under the compiled look and kept as
/// attachments: what the screen says is read off the pictures, since `simctl` cannot tap through
/// Settings to it.
@MainActor
final class ConnectionsScreenshots: XCTestCase {
    func testTheScreenInEachState() async throws {
        let store = InMemoryConnectionStore()
        let github = HeldGitHub()
        let connections = Connections(store: store, flow: github, copy: { _ in }, browser: RecordingBrowser())
        try attach(connections, "connections-disconnected")

        connections.connectGitHub()
        await github.reach(.token)
        for _ in 0..<20 { await Task.yield() }
        try attach(connections, "connections-waiting")

        connections.cancelGitHub()
        try store.save(Connection(token: "ghu_x", account: "samdu"), for: .github)
        try attach(Connections(store: store, flow: github, copy: { _ in }, browser: RecordingBrowser()), "connections-connected")
        github.release(.token)
    }

    private func attach(_ connections: Connections, _ name: String) throws {
        let image = try LookStage.image(ConnectionsView().environment(connections), look: Look())
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
