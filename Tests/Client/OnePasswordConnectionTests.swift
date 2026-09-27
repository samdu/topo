import TopoAuth
import TopoTools
import TopoUserland
import XCTest
@testable import Topo

/// `op` standing in for the guest's: records each call's arguments and token, and answers what
/// the test set, after a gate the test can hold.
private final class HeldOnePassword: OnePasswordRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [OnePasswordExit] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holding = false
    private var reached: CheckedContinuation<Void, Never>?
    private(set) var calls: [(arguments: [String], token: String)] = []
    private(set) var cancelled = 0

    func answer(_ exit: OnePasswordExit) { lock.withLock { answers.append(exit) } }
    func hold() { lock.withLock { holding = true } }

    /// Waits until a call is waiting at the gate.
    func reach() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if held != nil { return true }
                reached = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }

    func run(_ arguments: [String], token: String) async throws -> OnePasswordExit {
        let wait = lock.withLock { () -> Bool in
            calls.append((arguments, token))
            return holding
        }
        if wait {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let arrived = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        held = continuation
                        defer { reached = nil }
                        return reached
                    }
                    arrived?.resume()
                }
            } onCancel: {
                self.lock.withLock { self.cancelled += 1 }
            }
        }
        return lock.withLock { answers.isEmpty ? OnePasswordExit(status: 1, output: "", errors: "no answer set") : answers.removeFirst() }
    }
}

private final class NoGitHub: GitHubConnecting, @unchecked Sendable {
    func start() async throws -> GitHubDeviceFlow.Code { throw CancellationError() }
    func token(for code: GitHubDeviceFlow.Code) async throws -> String { throw CancellationError() }
    func login(token: String) async throws -> String { throw CancellationError() }
}

@MainActor
private final class FakePasteboard: Pasteboard {
    var changeCount = 7
    var clears = 0
    func clear() { clears += 1; changeCount += 1 }
}

private final class NoBrowser: Browser {
    func open(_ url: URL) {}
    func close() {}
}

private let token = "ops_" + String(repeating: "eyJhbGciOi", count: 8)
private let twoVaults = #"[{"id":"v1","name":"Homelab"},{"id":"v2","name":"Shared"}]"#

@MainActor
final class OnePasswordConnectionTests: XCTestCase {
    private var store: InMemoryConnectionStore!
    private var op: HeldOnePassword!
    private var pasteboard: FakePasteboard!

    override func setUp() async throws {
        store = InMemoryConnectionStore()
        op = HeldOnePassword()
        pasteboard = FakePasteboard()
    }

    private func connections() -> Connections {
        Connections(store: store, flow: NoGitHub(), onePassword: op, pasteboard: pasteboard, copy: { _ in }, browser: NoBrowser(), leftBehind: .isolated())
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testAPastedTokenIsCheckedWithVaultListAndSavedWithTheVaults() async throws {
        op.answer(OnePasswordExit(status: 0, output: twoVaults, errors: ""))
        let connections = connections()
        connections.connectOnePassword(pasted: "  \(token)\n")
        XCTAssertEqual(connections.onePassword, .verifying)
        await settle()
        XCTAssertEqual(connections.onePassword, .connected(vaults: "Homelab, Shared"))
        XCTAssertEqual(op.calls.map(\.arguments), [["vault", "list", "--format", "json"]])
        XCTAssertEqual(op.calls.map(\.token), [token], "the token is trimmed and handed over as it was pasted")
        XCTAssertEqual(try store.load(.onePassword), Connection(token: token, account: "Homelab, Shared"))
        XCTAssertEqual(self.connections().onePassword, .connected(vaults: "Homelab, Shared"), "a relaunch reads it back")
    }

    /// The pasted token leaves the pasteboard once it is kept, and not before: a refused one stays
    /// for the person to see, and something copied since is not theirs to lose.
    func testThePasteboardIsClearedOnceTheTokenIsKept() async throws {
        op.answer(OnePasswordExit(status: 0, output: twoVaults, errors: ""))
        let connections = connections()
        connections.connectOnePassword(pasted: token)
        await settle()
        XCTAssertEqual(connections.onePassword, .connected(vaults: "Homelab, Shared"))
        XCTAssertEqual(pasteboard.clears, 1)

        op.answer(OnePasswordExit(status: 1, output: "", errors: "[ERROR] no\n"))
        connections.connectOnePassword(pasted: token)
        await settle()
        XCTAssertEqual(pasteboard.clears, 1, "a refused token is not cleared")

        op.hold()
        op.answer(OnePasswordExit(status: 0, output: twoVaults, errors: ""))
        connections.connectOnePassword(pasted: token)
        await op.reach()
        pasteboard.changeCount += 1
        op.release()
        await settle()
        XCTAssertEqual(pasteboard.clears, 1, "something copied since the paste is left alone")
    }

    /// Cancel, Disconnect and a sign-out end an `op` still running, not only its answer.
    func testLeavingACheckEndsTheRunningOp() async throws {
        for leave in ["cancel", "disconnect", "forget"] {
            store = InMemoryConnectionStore()
            op = HeldOnePassword()
            op.hold()
            op.answer(OnePasswordExit(status: 0, output: twoVaults, errors: ""))
            let connections = connections()
            connections.connectOnePassword(pasted: token)
            await op.reach()
            switch leave {
            case "cancel": connections.cancelOnePassword()
            case "disconnect": connections.disconnectOnePassword()
            default: connections.forget()
            }
            await settle()
            XCTAssertEqual(op.cancelled, 1, leave)
            op.release()
            await settle()
            XCTAssertEqual(connections.onePassword, .disconnected, leave)
            XCTAssertNil(try store.load(.onePassword), leave)
        }
    }

    func testTextThatIsNotAServiceAccountTokenIsRefusedWithoutRunningOp() async {
        let connections = connections()
        for pasted in ["", "ghp_abc", "ops_", "ops_a b", "ops_a\nops_b", "hello ops_abc"] {
            connections.connectOnePassword(pasted: pasted)
            guard case let .failed(words) = connections.onePassword else { return XCTFail("\(pasted): \(connections.onePassword)") }
            XCTAssertTrue(words.contains("ops_"), words)
        }
        XCTAssertTrue(op.calls.isEmpty)
        XCTAssertNil(try store.load(.onePassword))
    }

    func testARefusedTokenIsSaidAndNotSaved() async throws {
        op.answer(OnePasswordExit(status: 1, output: "", errors: "[ERROR] invalid token\n"))
        let connections = connections()
        connections.connectOnePassword(pasted: token)
        await settle()
        XCTAssertEqual(connections.onePassword, .failed("1Password refused the token: [ERROR] invalid token"))
        XCTAssertNil(try store.load(.onePassword))
    }

    func testAnAccountThatReachesNoVaultIsNotSaved() async throws {
        op.answer(OnePasswordExit(status: 0, output: "[]", errors: ""))
        let connections = connections()
        connections.connectOnePassword(pasted: token)
        await settle()
        guard case let .failed(words) = connections.onePassword else { return XCTFail("\(connections.onePassword)") }
        XCTAssertTrue(words.contains("no vault"), words)
        XCTAssertNil(try store.load(.onePassword))
    }

    /// A check walked away from — cancelled, or the phone signed out or taken over — saves nothing
    /// when op answers after it.
    func testACheckAnsweringAfterCancelOrForgetSavesNothing() async throws {
        for leave in ["cancel", "forget"] {
            store = InMemoryConnectionStore()
            op = HeldOnePassword()
            op.hold()
            op.answer(OnePasswordExit(status: 0, output: twoVaults, errors: ""))
            let connections = connections()
            connections.connectOnePassword(pasted: token)
            await op.reach()
            if leave == "cancel" { connections.cancelOnePassword() } else { connections.forget() }
            XCTAssertEqual(connections.onePassword, .disconnected, leave)
            op.release()
            await settle()
            XCTAssertEqual(connections.onePassword, .disconnected, leave)
            XCTAssertNil(try store.load(.onePassword), leave)
        }
    }

    func testDisconnectAndForgetClearTheToken() async throws {
        try store.save(Connection(token: token, account: "Homelab"), for: .onePassword)
        let connections = connections()
        XCTAssertEqual(connections.onePassword, .connected(vaults: "Homelab"))
        connections.disconnectOnePassword()
        XCTAssertEqual(connections.onePassword, .disconnected)
        XCTAssertNil(try store.load(.onePassword))

        try store.save(Connection(token: token, account: "Homelab"), for: .onePassword)
        try store.save(Connection(token: "gho_x", account: "samdu"), for: .github)
        let again = self.connections()
        again.forget()
        XCTAssertNil(try store.load(.onePassword))
        XCTAssertNil(try store.load(.github))
        XCTAssertEqual(again.onePassword, .disconnected)
    }
}

final class SecretToolTests: XCTestCase {
    private func tool(connected: Bool = true, _ answers: OnePasswordExit...) -> (SecretTool, HeldOnePassword) {
        let op = HeldOnePassword()
        answers.forEach(op.answer)
        let store = InMemoryConnectionStore(connected ? [.onePassword: Connection(token: token, account: "Homelab")] : [:])
        return (SecretTool(store: store, onePassword: op, leftBehind: .isolated()), op)
    }

    func testEachCallAsksOpForAReadAndNothingElse() {
        XCTAssertEqual(SecretTool.parse(["vaults"])?.arguments, ["vault", "list", "--format", "json"])
        XCTAssertEqual(SecretTool.parse(["list"])?.arguments, ["item", "list", "--format", "json"])
        XCTAssertEqual(SecretTool.parse(["list", "Homelab"])?.arguments, ["item", "list", "--vault", "Homelab", "--format", "json"])
        XCTAssertEqual(SecretTool.parse(["get", "op://Homelab/Router/password"])?.arguments,
                       ["read", "--no-newline", "--", "op://Homelab/Router/password"])
        XCTAssertEqual(SecretTool.parse(["get", "op://Homelab/Router/admin/password"])?.arguments.last,
                       "op://Homelab/Router/admin/password")
    }

    /// While a clear the keychain refused at an earlier sign-out stands, `op` is not run with the
    /// token that login connected, whoever asks.
    func testARefusedClearAtAnEarlierSignOutRunsNoOp() async {
        let op = HeldOnePassword()
        let leftBehind = ConnectionsLeftBehind.isolated()
        leftBehind.words = "the connections' tokens could not be removed from this phone's keychain: -25308"
        let store = InMemoryConnectionStore([.onePassword: Connection(token: token, account: "Homelab")])
        let tool = SecretTool(store: store, onePassword: op, leftBehind: leftBehind)
        let reply = await tool.run(["vaults"])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertTrue(reply.text.contains("could not be removed"), reply.text)
        XCTAssertTrue(op.calls.isEmpty, "op ran with an earlier login's token")
    }

    func testAnythingElseIsUsage() {
        for arguments in [[], ["read", "op://a/b/c"], ["list", "--account", "x"], ["list", ""], ["list", "a", "b"],
                          ["get"], ["get", "Homelab/Router/password"], ["get", "op://a/b"], ["get", "op://a//c"],
                          ["get", "op://a/b/c/d/e"], ["get", "op://a/b/c\n"], ["get", "op://a/b/c", "--reveal"],
                          ["vaults", "x"], ["item", "delete", "x"], ["signin"]] {
            XCTAssertNil(SecretTool.parse(arguments), "\(arguments)")
        }
    }

    func testVaultsListAndGetAnswerOpsOutputAndHandOverTheToken() async {
        let (tool, op) = tool(OnePasswordExit(status: 0, output: twoVaults, errors: ""),
                              OnePasswordExit(status: 0, output: #"[{"id":"i1","title":"Router","category":"LOGIN","vault":{"name":"Homelab"}}]"#, errors: ""),
                              OnePasswordExit(status: 0, output: "hunter2", errors: ""))
        let vaults = await tool.run(["vaults"])
        XCTAssertEqual(vaults.status, 0)
        XCTAssertTrue(vaults.text.contains("v1") && vaults.text.contains("Homelab") && vaults.text.contains("Shared"), vaults.text)
        let list = await tool.run(["list"])
        XCTAssertTrue(list.text.contains("i1") && list.text.contains("Router") && list.text.contains("LOGIN"), list.text)
        let get = await tool.run(["get", "op://Homelab/Router/password"])
        XCTAssertEqual(get, .ok("hunter2\n"))
        XCTAssertEqual(op.calls.map(\.token), [token, token, token])
        for reply in [vaults, list, get] { XCTAssertFalse(reply.text.contains(token), "the token is never answered") }
    }

    func testNotConnectedIsSaidAndOpNeverRuns() async {
        let (tool, op) = tool(connected: false)
        let reply = await tool.run(["vaults"])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertEqual(reply.text, SecretTool.notConnected)
        XCTAssertTrue(op.calls.isEmpty)
    }

    func testOpsRefusalIsItsErrorLinesWithoutItsNotes() async {
        let (tool, _) = tool(OnePasswordExit(status: 1, output: "", errors: """
        couldn't start daemon: operation not permitted
        Using configuration at non-standard location "/tmp/tmp.cJFAhj"
        [ERROR] 2026/09/27 18:27:00 could not read secret 'op://Homelab/x/password': no item matched
        """))
        let reply = await tool.run(["get", "op://Homelab/x/password"])
        XCTAssertEqual(reply.text, "op: [ERROR] 2026/09/27 18:27:00 could not read secret 'op://Homelab/x/password': no item matched\n")
    }

    func testOpsRefusalIsSaidInItsWords() async {
        let (tool, _) = tool(OnePasswordExit(status: 1, output: "", errors: "[ERROR] \"Nope\" isn't an item\n"))
        let reply = await tool.run(["get", "op://Homelab/Nope/password"])
        XCTAssertEqual(reply.status, ToolReply.failed)
        XCTAssertEqual(reply.text, "op: [ERROR] \"Nope\" isn't an item\n")
    }
}

/// `GuestOnePassword`: `op` installed before every run, the token handed to the run and never an
/// argument, and never in what comes back.
final class GuestOnePasswordTests: XCTestCase {
    private final class Steps: @unchecked Sendable {
        let lock = NSLock()
        var steps: [String] = []
        var arguments: [[String]] = []
        func add(_ step: String) { lock.withLock { steps.append(step) } }
    }

    func testOpIsInstalledFirstAndTheTokenIsNeverAnArgumentOrAnAnswer() async throws {
        let steps = Steps()
        let runner = GuestOnePassword(install: { steps.add("install") }, runner: { arguments, handed in
            steps.add("run")
            steps.lock.withLock { steps.arguments.append(arguments) }
            XCTAssertEqual(handed, token)
            return Guest.Exit(status: 1, output: "", errors: "[ERROR] \(handed) is not valid\n")
        })
        let exit = try await runner.run(["vault", "list", "--format", "json"], token: token)
        XCTAssertEqual(steps.steps, ["install", "run"], "op is installed at its pin before it runs")
        XCTAssertEqual(steps.arguments, [["vault", "list", "--format", "json"]])
        XCTAssertFalse(steps.arguments.joined().contains(token))
        XCTAssertEqual(exit.errors, "[ERROR] [token] is not valid\n")
    }

    func testAFailedInstallRunsNothing() async {
        let steps = Steps()
        struct Refused: Error {}
        let runner = GuestOnePassword(install: { throw Refused() }, runner: { _, _ in
            steps.add("run")
            return Guest.Exit(status: 0, output: "", errors: "")
        })
        do {
            _ = try await runner.run(["vault", "list"], token: token)
            XCTFail("a failed install ran op")
        } catch {}
        XCTAssertTrue(steps.steps.isEmpty)
    }

    /// A check cancelled while `op` is installing (the first connect downloads it) runs no `op`,
    /// even when the install itself goes on to finish.
    func testACancelDuringTheInstallRunsNoOp() async throws {
        let steps = Steps()
        let gate = Gate()
        let runner = GuestOnePassword(install: { steps.add("install"); await gate.wait() }, runner: { _, _ in
            steps.add("run")
            return Guest.Exit(status: 0, output: "[]", errors: "")
        })
        let token = token
        let check = Task { try await runner.run(["vault", "list"], token: token) }
        for _ in 0..<200 where steps.lock.withLock({ steps.steps.isEmpty }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        check.cancel()
        gate.open()
        do {
            _ = try await check.value
            XCTFail("a check cancelled during the install answered")
        } catch is CancellationError {}
        XCTAssertEqual(steps.steps, ["install"], "a check cancelled during the install ran op")
    }

    /// A wait the test opens, which cancellation does not end: the shared install goes on.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if opened { return true }
                    waiting = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func open() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }
}
