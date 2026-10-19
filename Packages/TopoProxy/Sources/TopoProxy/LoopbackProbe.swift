import Foundation

/// Whether something is listening on `127.0.0.1` at a port: a TCP connect, closed as soon as it is
/// answered, bounded by `within`. A listener iOS took away while the app was suspended refuses at
/// once on loopback, whether or not its own listener has been told yet, so a held port is vouched
/// for by this rather than by the state the listener last reported. The connect runs on a queue of
/// its own, never the cooperative pool. Both servers here read an empty connection as a client
/// that left, and say nothing of it.
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
