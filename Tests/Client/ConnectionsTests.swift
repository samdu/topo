import Foundation
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
        XCTAssertEqual(try store.load(.github), Connection(token: "gho_token", account: "samdu"))
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
    static func isolated() -> ConnectionsLeftBehind {
        ConnectionsLeftBehind(defaults: UserDefaults(suiteName: "topo-tests-\(UUID().uuidString)")!)
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

/// The Connections screen in its three standing states, drawn under the compiled look and kept as
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

        connections.cancelGitHub()
        try store.save(Connection(token: "gho_x", account: "samdu"), for: .github)
        let reopened = Connections(store: store, flow: github, copy: { _ in }, browser: RecordingBrowser(), leftBehind: .isolated())
        guard case .connected = reopened.github else { return XCTFail("not connected: \(reopened.github)") }
        let connected = try attach(reopened, "connections-connected")
        github.release(.token)

        for (name, image) in [("disconnected", disconnected), ("waiting", waiting), ("connected", connected)] {
            XCTAssertGreaterThan(try colours(image), 8, "\(name) is drawn as a blank screen")
        }
        let pictures = try [disconnected, waiting, connected].map { try XCTUnwrap($0.pngData()) }
        XCTAssertEqual(Set(pictures).count, 3, "two states are drawn the same")
    }

    private func attach(_ connections: Connections, _ name: String) throws -> UIImage {
        let image = try LookStage.image(ConnectionsView().environment(connections), look: Look())
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
