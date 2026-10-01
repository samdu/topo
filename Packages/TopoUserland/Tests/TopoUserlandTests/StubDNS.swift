import Foundation

/// A name server over UDP standing in for a network's: it answers every A question with
/// `address` and every other type with no answers, and counts what it was asked. On `127.0.0.1`
/// at a port of its own, or, as `onPort53`, where a `resolv.conf` can name it: port 53, which
/// Darwin lets an unprivileged process bind only on every address, so it answers loopback peers
/// alone. Blocking reads on a thread of its own; `stop` closes the socket, which ends them.
final class StubDNS: @unchecked Sendable {
    let port: UInt16
    let address: [UInt8]
    private let fd: Int32
    private let lock = NSLock()
    private var asked = 0

    private let loopbackOnly: Bool

    init(address: [UInt8], onPort53: Bool = false) throws {
        self.address = address
        loopbackOnly = onPort53
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        self.fd = fd
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = onPort53 ? INADDR_ANY : inet_addr("127.0.0.1")
        local.sin_port = onPort53 ? UInt16(53).bigEndian : 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        port = UInt16(bigEndian: local.sin_port)
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    var queries: Int { lock.withLock { asked } }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength)
                }
            }
            guard count > 0 else { return }
            let fromLoopback = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_family == sa_family_t(AF_INET) && $0.pointee.sin_addr.s_addr == inet_addr("127.0.0.1")
                }
            }
            guard fromLoopback || !loopbackOnly else { continue }
            lock.withLock { asked += 1 }
            guard let reply = answer(Array(buffer[0..<count])) else { continue }
            _ = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, reply, reply.count, 0, $0, peerLength)
                }
            }
        }
    }

    /// The reply to one query: its id and question, and one A record for an A question.
    private func answer(_ query: [UInt8]) -> [UInt8]? {
        guard query.count > 12 else { return nil }
        var end = 12
        while end < query.count, query[end] != 0 { end += Int(query[end]) + 1 }
        end += 5
        guard end <= query.count else { return nil }
        let type = UInt16(query[end - 4]) << 8 | UInt16(query[end - 3])
        let isA = type == 1
        var reply = Array(query[0..<2]) + [0x81, 0x80, 0, 1, 0, isA ? 1 : 0, 0, 0, 0, 0]
        reply += query[12..<end]
        if isA { reply += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + address }
        return reply
    }
}
