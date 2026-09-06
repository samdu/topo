import Foundation
import Network
import TopoCore

/// The Bonjour service every Topo device advertises on the LAN. Its name is
/// the device ID, so a browse of the type is a roster of who is here.
public enum TopoService {
    public static let type = "_topo._tcp"
}

/// The wire form of a lease probe: one line each way over TCP.
/// `hold <device> <epoch>` asks whether the listener still holds that lease;
/// `yes` or `no` answers. Anything else, or silence, is no.
enum ProbeWire {
    static func request(_ lease: Lease) -> Data {
        Data("hold \(lease.holder.rawValue) \(lease.epoch)\n".utf8)
    }

    static func parseRequest(_ line: String) -> (DeviceID, Int64)? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3, parts[0] == "hold", let epoch = Int64(parts[2]) else { return nil }
        return (DeviceID(String(parts[1])), epoch)
    }

    static let yes = Data("yes\n".utf8)
    static let no = Data("no\n".utf8)

    struct LineTooLong: Error {}
}

/// Answers lease probes and live turns, and advertises the device on the LAN.
///
/// The probe's answer comes from `holds`, which the owner points at its
/// `PrimaryLease`: true only for the lease it holds right now, epoch
/// included, so a device that restarted or lost the lease says no and the
/// asker claims. A turn's answer comes from `answers`, which the owner
/// points at its harness: the reply turn it wrote for the ref, or nil, sent
/// as `no`; an owner with no brain leaves it nil. One listener does every
/// job: it is the endpoint the lease record names, and its Bonjour
/// registration is the device's presence. Each connection is served in its
/// own task, so a long answer never holds up a probe.
public actor LeaseProbeServer {
    public typealias Holds = @Sendable (DeviceID, Int64) async -> Bool
    public typealias Answers = @Sendable (TurnRef) async -> LiveReply?

    private let listener: NWListener
    private let holds: Holds
    private let answers: Answers?
    private var ready: CheckedContinuation<UInt16, any Error>?
    public private(set) var port: UInt16?

    /// - Parameters:
    ///   - advertising: the device ID to register under `TopoService.type`,
    ///     or nil to listen without advertising.
    ///   - port: 0 picks a free one.
    public init(advertising device: DeviceID?, port: UInt16 = 0, answers: Answers? = nil, holds: @escaping Holds) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if let device {
            listener.service = NWListener.Service(name: device.rawValue, type: TopoService.type)
        }
        self.listener = listener
        self.holds = holds
        self.answers = answers
    }

    /// Starts listening. Returns the port once bound.
    public func start() async throws -> UInt16 {
        if let port { return port }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.stateChanged(state) }
        }
        listener.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.listener"))
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
        }
    }

    public func stop() {
        listener.cancel()
        port = nil
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let bound = listener.port?.rawValue ?? 0
            port = bound
            ready?.resume(returning: bound)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        case .cancelled:
            ready?.resume(throwing: CancellationError())
            ready = nil
        default:
            break
        }
    }

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.serve"))
        defer { connection.cancel() }
        guard let line = try? await connection.readLine(maximum: 256) else {
            try? await connection.send(ProbeWire.no)
            return
        }
        if let (device, epoch) = ProbeWire.parseRequest(line) {
            let answer = await holds(device, epoch)
            try? await connection.send(answer ? ProbeWire.yes : ProbeWire.no)
        } else if let ref = TurnWire.parseRequest(line), let answers, let reply = await answers(ref) {
            try? await connection.send(TurnWire.reply(reply.ref, reply.text))
        } else {
            try? await connection.send(ProbeWire.no)
        }
    }
}

/// Probes a lease holder over TCP at the `host:port` its lease names.
///
/// True only when the holder is reached within the timeout and answers
/// `yes` to this lease. A closed port, a timeout, a refusal or garbage is
/// false, which is what makes the asker claim.
public struct SocketLeaseProbe: LeaseProbe {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 2) {
        self.timeout = timeout
    }

    public func confirms(_ lease: Lease) async -> Bool {
        guard let endpoint = lease.endpoint, let (host, port) = Self.parse(endpoint) else { return false }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        // The deadline cancels the connection, which fails whichever step is
        // pending; nothing here waits on anything the cancel cannot reach.
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
        }
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.probe"))
        guard (try? await connection.waitUntilReady()) != nil,
              (try? await connection.send(ProbeWire.request(lease))) != nil,
              let line = try? await connection.readLine(maximum: 16) else { return false }
        return line.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    /// `host:port` or `[v6]:port`.
    static func parse(_ endpoint: String) -> (NWEndpoint.Host, NWEndpoint.Port)? {
        guard let colon = endpoint.lastIndex(of: ":"),
              let number = UInt16(endpoint[endpoint.index(after: colon)...]),
              let port = NWEndpoint.Port(rawValue: number) else { return nil }
        var host = String(endpoint[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        return (NWEndpoint.Host(host), port)
    }
}

extension NWConnection {
    func waitUntilReady() async throws {
        let box = OneShot<Void>()
        stateUpdateHandler = { state in
            switch state {
            case .ready: box.resume(.success(()))
            case .failed(let error): box.resume(.failure(error))
            // A refused or unroutable connection waits for the network to
            // change rather than failing; for a probe that is a no.
            case .waiting(let error): box.resume(.failure(error))
            case .cancelled: box.resume(.failure(CancellationError()))
            default: break
            }
        }
        try await box.value()
    }

    func send(_ data: Data) async throws {
        let box = OneShot<Void>()
        send(content: data, completion: .contentProcessed { error in
            if let error { box.resume(.failure(error)) } else { box.resume(.success(())) }
        })
        try await box.value()
    }

    /// Reads until a newline, the end of the stream, or `maximum` bytes,
    /// however TCP splits it, and returns the line without its newline.
    func readLine(maximum: Int) async throws -> String {
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: buffer[..<newline], as: UTF8.self)
            }
            guard buffer.count < maximum else { throw ProbeWire.LineTooLong() }
            let (chunk, complete) = try await receiveSome(maximum: maximum - buffer.count)
            if let chunk { buffer.append(chunk) }
            // The end of the stream may arrive with the newline; the newline wins.
            if complete, !buffer.contains(UInt8(ascii: "\n")) {
                return String(decoding: buffer, as: UTF8.self)
            }
        }
    }

    func receiveSome(maximum: Int) async throws -> (Data?, Bool) {
        let box = OneShot<ReceivedChunk>()
        receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
            if let error { box.resume(.failure(error)); return }
            box.resume(.success(ReceivedChunk(data: data, complete: complete)))
        }
        let chunk = try await box.value()
        return (chunk.data, chunk.complete)
    }
}

struct ReceivedChunk: Sendable {
    var data: Data?
    var complete: Bool
}

/// A continuation that can only be resumed once, whichever callback fires.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    func resume(_ r: Result<T, any Error>) {
        let c: CheckedContinuation<T, any Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = r
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: r)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            let ready: Result<T, any Error>? = lock.withLock {
                if let result { return result }
                continuation = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }
    }
}
