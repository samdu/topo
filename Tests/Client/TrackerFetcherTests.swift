import Foundation
import Network
import XCTest

@testable import Topo

/// An HTTP server on loopback in the test process, so the transport's own behaviour is what is
/// measured: a redirect declined, a body past the cap refused, the deadline met.
private final class TrackerServer: @unchecked Sendable {
    enum Behaviour {
        case answer(Int, body: String, headers: [String: String] = [:])
        /// A 200 whose body goes on past the cap.
        case endless
        /// Reads the request and never answers.
        case stall
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tracker-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _requests = 0
    let behaviour: Behaviour
    private(set) var port: UInt16 = 0
    var requests: Int { lock.withLock { _requests } }

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

    var url: URL { URL(string: "http://127.0.0.1:\(port)/progress/x")! }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] _, _, _, _ in
            lock.withLock { _requests += 1 }
            respond(connection)
        }
    }

    private func respond(_ connection: NWConnection) {
        switch behaviour {
        case .answer(let status, let body, let headers):
            let lines = ["HTTP/1.1 \(status) Status", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers.map { "\($0.key): \($0.value)" }
            connection.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        case .endless:
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in chunk(connection, 0) })
        case .stall:
            break
        }
    }

    /// 8 KB a chunk, for as long as the client reads.
    private func chunk(_ connection: NWConnection, _ count: Int) {
        guard count < 64 else { return }
        let piece = String(repeating: "x", count: 8192)
        let data = Data((String(piece.utf8.count, radix: 16) + "\r\n" + piece + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { [self] error in
            guard error == nil else { return }
            queue.async { self.chunk(connection, count + 1) }
        })
    }
}

/// Review Focus 3: `URLTrackerFetcher` against a real server — a 2xx body is answered, a redirect
/// is not followed, a body past the cap is refused, and a stall ends at the deadline.
final class TrackerFetcherTests: XCTestCase {
    private var servers: [TrackerServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
    }

    private func server(_ behaviour: TrackerServer.Behaviour) async throws -> TrackerServer {
        let made = try await TrackerServer(behaviour)
        servers.append(made)
        return made
    }

    func testAnswersATwoHundredBody() async throws {
        let server = try await server(.answer(200, body: TrackerFixtures.wiki))
        let fetched = await URLTrackerFetcher().fetch(server.url)
        let data = try XCTUnwrap(fetched)
        XCTAssertEqual(ProgressTracker.read(data).tracker?.title, "macOS update on buddybox")
        let notFound = try await self.server(.answer(404, body: "{}"))
        let missing = await URLTrackerFetcher().fetch(notFound.url)
        XCTAssertNil(missing)
        let broken = try await self.server(.answer(500, body: TrackerFixtures.wiki))
        let failed = await URLTrackerFetcher().fetch(broken.url)
        XCTAssertNil(failed)
    }

    func testRedirectRefused() async throws {
        let target = try await server(.answer(200, body: TrackerFixtures.wiki))
        let redirect = try await server(.answer(302, body: "", headers: ["Location": target.url.absoluteString]))
        let redirected = await URLTrackerFetcher().fetch(redirect.url)
        XCTAssertNil(redirected)
        XCTAssertEqual(target.requests, 0, "the redirect was not followed")
        XCTAssertEqual(redirect.requests, 1)
    }

    func testBodyCapped() async throws {
        let server = try await server(.endless)
        let began = ContinuousClock.now
        let capped = await URLTrackerFetcher(cap: 16 * 1024).fetch(server.url)
        XCTAssertNil(capped)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5), "refused at the cap, not at the deadline")
        let declared = try await self.server(.answer(200, body: String(repeating: "y", count: 2000), headers: [:]))
        let oversized = await URLTrackerFetcher(cap: 1000).fetch(declared.url)
        XCTAssertNil(oversized, "a declared length past the cap is refused")
    }

    func testDeadline() async throws {
        let server = try await server(.stall)
        let began = ContinuousClock.now
        let stalled = await URLTrackerFetcher(deadline: .seconds(1)).fetch(server.url)
        XCTAssertNil(stalled)
        let took = ContinuousClock.now - began
        XCTAssertGreaterThanOrEqual(took, .milliseconds(900))
        XCTAssertLessThan(took, .seconds(4))
    }
}
