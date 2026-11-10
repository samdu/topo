import Foundation
import Network

/// Whether something is listening on `127.0.0.1` at a port: a TCP connect, closed as soon as it
/// is answered, bounded by `within`, run off the cooperative pool.
public enum LoopbackProbe {
    public static let patience: Duration = .seconds(1)

    public static func answers(port: UInt16, within: Duration = patience) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: connects(port: port, within: within))
            }
        }
    }

    static func connects(port: UInt16, within: Duration) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poll = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(within / .milliseconds(1))
        guard Darwin.poll(&poll, 1, milliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

/// Another listener on `127.0.0.1` at `port`, as a process that took a port iOS freed would be:
/// it accepts and closes, and answers nothing. Ready when returned.
public func squat(_ port: UInt16) async throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { $0.cancel() }
    let once = SquatReady()
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.continuation = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(nil)
                case .failed(let error), .waiting(let error): once.resume(error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.squat"))
        }
    } catch {
        // A squat refused lets its listener go, so a search past held ports leaves none behind.
        listener.cancel()
        throw error
    }
    return listener
}

final class SquatReady: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Void, Error>?
    func resume(_ error: Error?) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}
