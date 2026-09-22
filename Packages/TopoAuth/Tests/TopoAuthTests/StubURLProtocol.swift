import CryptoKit
import Foundation
import Testing

/// Every suite that talks to `StubURLProtocol` sits under here, so they run one at a time and
/// never read each other's stubbed reply.
@Suite(.serialized) enum Stubbed {}

func import_CryptoKit_sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

/// Answers every request from the last `respond(...)`; records the request and its body.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    /// Runs while the request is in flight, before the reply lands.
    nonisolated(unsafe) static var beforeResponse: (@Sendable () -> Void)?
    /// Answers each request from its body instead of the last `respond(...)`, when set: for a flow
    /// that makes more than one request and needs a different answer to each.
    nonisolated(unsafe) static var responder: (@Sendable (_ body: [String: Any]) -> (status: Int, json: String))?
    /// Every request body since the last `reset()`, in order.
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        responder = nil
        bodies = []
        beforeResponse = nil
    }

    static func respond(status: Int, json: String) {
        self.status = status
        self.body = Data(json.utf8)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        Self.beforeResponse?()
        let sent = Self.lastBody ?? Data()
        Self.bodies.append(sent)
        var status = Self.status, body = Self.body
        if let responder = Self.responder {
            let answer = responder((try? JSONSerialization.jsonObject(with: sent) as? [String: Any]) ?? [:])
            status = answer.status
            body = Data(answer.json.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
