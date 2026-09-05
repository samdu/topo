import Foundation
import TopoAuth
import TopoCore
@testable import TopoTurn

/// Records every request and answers from a queue.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var replies: [(Int, String)] = []
    /// Runs while a request is in flight, before its reply.
    var duringRequest: (@Sendable () async -> Void)?

    init(_ replies: (Int, String)...) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await duringRequest?()
        return lock.withLock {
            requests.append(request)
            let (status, body) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    var lastBody: [String: Any]? {
        guard let data = requests.last?.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct FixedToken: TokenProvider {
    var token = "tok"
    func accessToken() async throws -> String { token }
}

struct AlwaysConfirms: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}

func reply(_ text: String, stop: String = "end_turn") -> String {
    #"{"id":"msg","type":"message","model":"claude-sonnet-5","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"\#(stop)","usage":{"input_tokens":10,"output_tokens":5}}"#
}

/// A runner over an in-memory log for one device, with a lease it can always take.
func makeRunner(database: any RecordDatabase, device: String = "phone", transport: Transport,
                probe: any LeaseProbe = NoSocketProbe()) async throws -> (TurnRunner, PrimaryLease) {
    let id = DeviceID(device)
    let log = TurnLog(database: database)
    let writer = try await log.writer(for: id)
    let lease = PrimaryLease(database: database, device: id, endpoint: nil, probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let api = MessagesAPI(transport: transport, tokens: FixedToken())
    return (TurnRunner(log: log, writer: writer, lease: lease, api: api), lease)
}
