import Foundation
import Network
import OSLog
import TopoTools
import XCTest

@testable import Topo

/// An HTTP server on loopback in the test process, counting the requests it receives, so what is
/// measured is the transport's behaviour and not a stub's.
private final class LoopbackServer: @unchecked Sendable {
    enum Behaviour {
        /// Answers each request with `status`, `headers` and `body`.
        case answer(Int, headers: [String: String] = [:], body: String = "")
        /// Reads the request and closes the connection unanswered.
        case drop
        /// Sends one byte of a status line a second, and never finishes.
        case trickle
        /// Reads the request and never answers.
        case stall
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var _requests: [String] = []
    private var connections: [NWConnection] = []
    let behaviour: Behaviour
    private(set) var port: UInt16 = 0

    /// Every request received, whole, in the order received.
    var requests: [String] { lock.withLock { _requests } }

    init(_ behaviour: Behaviour) async throws {
        self.behaviour = behaviour
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] connection in self.accept(connection) }
        let ready: AsyncStream<UInt16> = AsyncStream { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
            }
        }
        listener.start(queue: queue)
        for await port in ready { self.port = port }
    }

    func url(_ path: String = "/") -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            var received = received
            if let data { received.append(data) }
            if let request = Self.complete(received) {
                lock.withLock { _requests.append(request) }
                respond(connection)
            } else if !done, error == nil {
                read(connection, received)
            }
        }
    }

    /// The request in `data`, once its headers and its body have all arrived.
    private static func complete(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n") else { return nil }
        let length = text[..<end.lowerBound].split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return text[end.upperBound...].utf8.count >= length ? text : nil
    }

    private func respond(_ connection: NWConnection) {
        switch behaviour {
        case .answer(let status, let headers, let body):
            let lines = ["HTTP/1.1 \(status) Status", "Content-Length: \(body.utf8.count)", "Connection: close"]
                + headers.map { "\($0.key): \($0.value)" }
            let response = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .drop:
            connection.cancel()
        case .trickle:
            trickle(connection, Array("HTTP/1.1 200 OK\r\nX-Slow: ".utf8) + Array(repeating: UInt8(ascii: "a"), count: 60))
        case .stall:
            break
        }
    }

    private func trickle(_ connection: NWConnection, _ bytes: [UInt8]) {
        guard let byte = bytes.first else { return }
        connection.send(content: Data([byte]), completion: .contentProcessed { [self] error in
            guard error == nil else { return }
            queue.asyncAfter(deadline: .now() + 1) { self.trickle(connection, Array(bytes.dropFirst())) }
        })
    }
}

/// Review Focus 13 and 14 of the controls' plan: one tap is one request under an absolute
/// deadline, no redirect followed and nothing retried, a secret resolved from the keychain at the
/// tap, and nothing a request carried kept anywhere.
@MainActor
final class ControlRequestTests: XCTestCase {
    private var folder: URL!
    private var secrets: ControlSecrets!
    private var leftBehind = ConnectionsLeftBehind.isolated()
    private var servers: [LoopbackServer] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("control-requests-\(UUID().uuidString)")
        secrets = ControlSecrets(service: "zone.hexagon.topo.control-secret.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        try? secrets.clearAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private var store: SurfaceStore { SurfaceStore(folder: folder) }

    private func server(_ behaviour: LoopbackServer.Behaviour) async throws -> LoopbackServer {
        let server = try await LoopbackServer(behaviour)
        servers.append(server)
        return server
    }

    private func actions(reloader: SurfaceReloader? = nil) -> WidgetActions {
        let store = store
        let secrets = secrets!
        let leftBehind = leftBehind
        return WidgetActions(table: ToolTable([]), store: { store },
                             reloader: reloader ?? SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in },
                                                                   reloadEveryControl: {}, schedule: { _, _ in }),
                             perform: { await ControlRequest.perform($0, secrets: secrets, leftBehind: leftBehind) })
    }

    /// Writes `button-1` making `request`, as `topo control set` would, and answers its revision.
    private func set(_ request: [String: Any]) throws -> Int {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["title": "Go", "action": request.merging(["kind": "request"]) { $1 }]),
                          as: UTF8.self)
        let reading = ControlDocument.read(text, slot: "button-1")
        XCTAssertEqual(reading.notes, [])
        return try store.writeControl(reading.document, slot: "button-1")
    }

    private func tap(_ actions: WidgetActions, revision: Int) async {
        await actions.run(slot: ControlSlot.stored("button-1"), control: ControlSlot.control, revision: revision, turningOn: nil)
    }

    private var last: SurfaceStore.Tap? { store.taps().last }

    func testOneRequestPerTap() async throws {
        let server = try await server(.answer(204))
        let revision = try set(["url": server.url("/api/ping"), "method": "POST", "body": "{}"])
        await tap(actions(), revision: revision)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(server.requests[0].hasPrefix("POST /api/ping HTTP/1.1"))
        XCTAssertEqual(last?.kind, "request")
        XCTAssertEqual(last?.status, "0")
        XCTAssertEqual(last?.code, 204)
    }

    func testPostNotResentOnADroppedConnection() async throws {
        let server = try await server(.drop)
        let revision = try set(["url": server.url("/api/treat"), "body": "{}"])
        await tap(actions(), revision: revision)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(server.requests.count, 1, "a POST was sent again on a dropped connection")
        XCTAssertEqual(last?.status, "1")
        XCTAssertNil(last?.code)
    }

    /// The transport resends a GET on a dropped connection, as HTTP permits of an idempotent
    /// method: measured at two resends, three received, and never more; a PUT and a DELETE are
    /// sent once. A POST's and a PATCH's single send is `postNotResentOnADroppedConnection`.
    func testIdempotentResendIsBounded() async throws {
        for (method, most) in [("GET", 3), ("PUT", 1), ("DELETE", 1), ("PATCH", 1)] {
            let server = try await server(.drop)
            let answer = await ControlRequest.perform(ControlRequest.Form(method: method, url: server.url("/api/state"),
                                                                          body: method == "GET" ? nil : "{}"),
                                                      secrets: secrets)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue((1...most).contains(server.requests.count), "\(server.requests.count) \(method)s for one tap")
            XCTAssertEqual(answer.status, ToolReply.failed)
        }
    }

    /// The hosts `LocalNetworkAccess` asks for: private and link-local addresses and `.local`
    /// names, and nothing on the internet.
    func testWhatIsLocal() {
        for url in ["http://192.168.1.214/api", "http://10.0.0.5", "http://172.16.0.1", "http://172.31.255.1", "http://169.254.1.1",
                    "http://hub.local:8123/x", "http://[fe80::1]/", "http://[fd12:3456::1]:8080/"] {
            XCTAssertTrue(LocalNetworkAccess.isLocal(URL(string: url)!), url)
        }
        for url in ["https://example.com", "http://172.32.0.1", "http://8.8.8.8", "http://[2001:db8::1]/", "http://192.169.0.1",
                    "https://local.example.com"] {
            XCTAssertFalse(LocalNetworkAccess.isLocal(URL(string: url)!), url)
        }
    }

    /// A server sending a byte a second never trips an inactivity timeout: the deadline is from
    /// start to answer.
    func testTrickleAnswersAtTheDeadline() async throws {
        let server = try await server(.trickle)
        let revision = try set(["url": server.url("/slow")])
        let started = ContinuousClock.now
        await tap(actions(), revision: revision)
        let took = ContinuousClock.now - started
        XCTAssertEqual(last?.status, String(ToolReply.timedOut))
        XCTAssertGreaterThanOrEqual(took, .seconds(9.5))
        XCTAssertLessThan(took, .seconds(12), "the deadline was not absolute: \(took)")
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRedirectNotFollowed() async throws {
        let server = try await server(.answer(302, headers: ["Location": "/elsewhere"]))
        let revision = try set(["url": server.url("/first")])
        await tap(actions(), revision: revision)
        XCTAssertEqual(server.requests.count, 1, "the redirect was followed: \(server.requests.map { $0.prefix(20) })")
        XCTAssertEqual(last?.status, "1")
        XCTAssertEqual(last?.code, 302)
    }

    func testServerErrorNotRetried() async throws {
        let server = try await server(.answer(500))
        let revision = try set(["url": server.url("/api/treat"), "method": "PUT", "body": "{}"])
        await tap(actions(), revision: revision)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(last?.status, "1")
        XCTAssertEqual(last?.code, 500)
    }

    /// The server receives the secret's value; the document in the app group holds its name.
    func testSecretResolvedAtTheTap() async throws {
        let server = try await server(.answer(200))
        try secrets.set("tok-7Q2X", name: "ha")
        let revision = try set(["url": server.url("/api"), "headers": ["Authorization": "Bearer ${secret:ha}"],
                                "body": #"{"key": "${secret:ha}"}"#])
        await tap(actions(), revision: revision)
        XCTAssertEqual(server.requests.count, 1)
        let received = server.requests[0]
        XCTAssertTrue(received.lowercased().contains("authorization: bearer tok-7q2x"), received)
        XCTAssertTrue(received.hasSuffix(#"{"key": "tok-7Q2X"}"#), received)
        let file = try String(contentsOf: folder.appendingPathComponent("_control-button-1.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("${secret:ha}"))
        XCTAssertFalse(file.contains("tok-7Q2X"))
        XCTAssertEqual(try secrets.names(), ["ha"])
    }

    func testMissingSecretSendsNothing() async throws {
        let server = try await server(.answer(200))
        let revision = try set(["url": server.url("/api"), "headers": ["Authorization": "Bearer ${secret:gone}"]])
        await tap(actions(), revision: revision)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertEqual(last?.status, "1")
        XCTAssertNil(last?.code)
    }

    /// A clear of the control secrets the keychain refused at a sign-out: a request naming a secret
    /// sends nothing, since what the keychain holds is the earlier login's; one naming none still goes.
    func testASecretLeftBehindSendsNothing() async throws {
        let server = try await server(.answer(204))
        try secrets.set("earlier", name: "ha")
        leftBehind.controlSecrets = "the controls' secrets could not be removed"
        let named = try set(["url": server.url("/api"), "headers": ["Authorization": "Bearer ${secret:ha}"]])
        await tap(actions(), revision: named)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests.count, 0, "a secret left behind at a sign-out was sent")
        XCTAssertEqual(last?.status, "1")
        let plain = try set(["url": server.url("/api")])
        await tap(actions(), revision: plain)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(last?.status, "0")
    }

    /// A sentinel in a header's value, a secret, the query, the body and the response: in no line
    /// of the tap log and no line this process logged.
    func testNothingItCarriedIsRecorded() async throws {
        let sentinels = ["SENTINEL-HEADER", "SENTINEL-SECRET", "SENTINEL-QUERY", "SENTINEL-BODY", "SENTINEL-RESPONSE"]
        let server = try await server(.answer(200, headers: ["X-Echo": "SENTINEL-RESPONSE"], body: "SENTINEL-RESPONSE"))
        try secrets.set("SENTINEL-SECRET", name: "ha")
        let started = Date()
        let revision = try set(["url": server.url("/api?token=SENTINEL-QUERY"),
                                "headers": ["X-Key": "SENTINEL-HEADER", "Authorization": "Bearer ${secret:ha}"],
                                "body": "SENTINEL-BODY"])
        await tap(actions(), revision: revision)
        XCTAssertEqual(last?.status, "0")
        let received = try XCTUnwrap(server.requests.first)
        for sentinel in sentinels.dropLast() { XCTAssertTrue(received.contains(sentinel), "\(sentinel) was never sent") }

        let taps = (try? String(contentsOf: folder.appendingPathComponent("_taps.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(taps.isEmpty)
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let logged = try logStore.getEntries(at: logStore.position(date: started)).map(\.composedMessage)
        for sentinel in sentinels {
            XCTAssertFalse(taps.contains(sentinel), "\(sentinel) is in the tap log")
            XCTAssertFalse(logged.contains { $0.contains(sentinel) }, "\(sentinel) is in a log line")
        }
    }

    /// Review Focus 8: a request stalled at a sign-out is cancelled, answers at once and records
    /// nothing.
    func testSignOutCancelsARequestInFlight() async throws {
        let server = try await server(.stall)
        let reloader = SurfaceReloader(reloadKind: { _ in }, reloadEverything: {}, reloadControlKind: { _ in },
                                       reloadEveryControl: {}, schedule: { _, _ in })
        let actions = actions(reloader: reloader)
        let revision = try set(["url": server.url("/api/stall"), "body": "{}"])
        let started = ContinuousClock.now
        let tapped = Task { await tap(actions, revision: revision) }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        reloader.forget(store)
        await tapped.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(store.taps(), [], "a request cancelled at sign-out was recorded")
    }
}
