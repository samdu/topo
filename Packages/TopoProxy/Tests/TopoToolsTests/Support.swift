import Foundation
import Network
import TopoProxy
@testable import TopoTools

/// A tool that records what it was called with and answers as it is told.
final class ScriptedTool: Tool, @unchecked Sendable {
    let name: String
    let summary = "a scripted tool"
    let usage = "topo scripted <anything>"
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let answer: @Sendable ([String]) async -> ToolReply

    init(name: String = "echo", answer: @escaping @Sendable ([String]) async -> ToolReply = { .ok($0.joined(separator: "|") + "\n") }) {
        self.name = name
        self.answer = answer
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ arguments: [String]) async -> ToolReply {
        lock.withLock { _calls.append(arguments) }
        return await answer(arguments)
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}

func startedService(_ tools: [any Tool], bound: Duration = ToolService.defaultBound)
    async throws -> (service: ToolService, port: UInt16, logs: LogLines) {
    let logs = LogLines()
    let service = try ToolService(tools: tools, bound: bound, log: { logs.add($0) })
    let port = try await service.start()
    return (service, port, logs)
}

/// One raw request on a fresh connection, and the status and body that came back — or nil status
/// when the connection closed with nothing said.
func exchange(port: UInt16, _ head: String, body: Data = Data(), host: NWEndpoint.Host = "127.0.0.1")
    async throws -> (status: Int?, body: String) {
    let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let inbound = Inbound(connection, limit: 1 << 20)
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { connection.cancel() }
    }
    defer { watchdog.cancel(); connection.cancel() }
    inbound.start(queue: DispatchQueue(label: "test.tools.client"))
    var data = Data(head.utf8)
    data.append(body)
    try await inbound.send(data)
    guard let raw = try await inbound.read(through: RequestReader.headEnd, maximum: 64 * 1024, tooLarge: .headTooLarge) else {
        return (nil, "")
    }
    let text = String(decoding: raw, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    let status = Int(lines[0].split(separator: " ")[1])
    let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let bodyData = length > 0 ? try await inbound.read(count: length) : Data()
    return (status, String(decoding: bodyData, as: UTF8.self))
}

/// A well-formed call, with whatever headers are given in place of the usual ones.
func call(port: UInt16, token: String, _ arguments: [String], extra: [String] = [],
          host: String? = nil, method: String = "POST", path: String = ToolService.path) -> (String, Data) {
    let body = ToolRequest.body(token: token, arguments)
    var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
    head += "Content-Length: \(body.count)\r\n"
    for line in extra { head += line + "\r\n" }
    head += "\r\n"
    return (head, body)
}
