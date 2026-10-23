import Foundation

/// A name server over UDP standing in for a network's: it answers every A question with
/// `address` and every other type with no answers, and counts what it was asked. On `127.0.0.1`
/// at a port of its own, or, as `onPort53`, where a `resolv.conf` can name it: port 53, which
/// Darwin lets an unprivileged process bind only on every address, so it answers loopback peers
/// alone. Blocking reads on a thread of its own, which `stop` wakes and waits out. A socket call
/// that fails throws its own errno.
///
/// Port 53 is borrowed when the environment names a holder (`TEST_RUNNER_TOPO_PORT53_SOCKET`, a
/// Unix socket): while a virtual machine runs on the Mac (a Tart runner's), vmnet's DNS proxy,
/// mDNSResponder, holds port 53 on every address, and a bind of it is EADDRINUSE until the
/// machine has stopped and the proxy let go. A socket bound there before any machine started
/// keeps every loopback datagram after the proxy binds beside it, so the Mac's holder keeps one
/// from its login and hands a copy of it to each caller. A borrowed socket is the holder's too:
/// it is closed and never shut down, since a shutdown would end it for the holder and every
/// later borrower. With no holder named, or one that refuses the connection or whose socket is
/// gone (a holder that died), the stub binds the port itself.
final class StubDNS: @unchecked Sendable {
    static let holderVariable = "TOPO_PORT53_SOCKET"

    let port: UInt16
    let address: [UInt8]
    private let fd: Int32
    private let wake: [Int32]
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var asked = 0

    private let loopbackOnly: Bool

    init(address: [UInt8], onPort53: Bool = false) throws {
        self.address = address
        loopbackOnly = onPort53
        var lent: Int32?
        if onPort53, let holder = ProcessInfo.processInfo.environment[Self.holderVariable], !holder.isEmpty {
            do {
                lent = try Self.borrow(from: holder)
            } catch let error as POSIXError where error.code == .ECONNREFUSED || error.code == .ENOENT {
                // A holder that died leaves its socket behind: nobody lends, and the stub binds.
            }
        }
        let fd: Int32
        if let lent {
            fd = lent
        } else {
            fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw Self.failure() }
            var local = Self.local(onPort53 ? INADDR_ANY : inet_addr("127.0.0.1"), port: onPort53 ? 53 : 0)
            let failure: POSIXError? = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? nil : Self.failure()
                }
            }
            if let failure { close(fd); throw failure }
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        guard named else { let failure = Self.failure(); close(fd); throw failure }
        port = UInt16(bigEndian: local.sin_port)
        guard !onPort53 || port == 53 else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { let failure = Self.failure(); close(fd); throw failure }
        self.fd = fd
        wake = ends
        // A borrowed socket can hold what an earlier borrower was sent after it stopped.
        var stale = [UInt8](repeating: 0, count: 512)
        while recv(fd, &stale, stale.count, MSG_DONTWAIT) >= 0 {}
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    var queries: Int { lock.withLock { asked } }

    /// Wakes the serving thread and waits for it to close the socket.
    func stop() {
        var byte: UInt8 = 0
        _ = write(wake[1], &byte, 1)
        done.wait()
    }

    private static func local(_ address: in_addr_t, port: UInt16) -> sockaddr_in {
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = address
        local.sin_port = port.bigEndian
        return local
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// A copy of the holder's socket, passed as `SCM_RIGHTS` over its Unix socket at `path`.
    private static func borrow(from path: String) throws -> Int32 {
        let link = socket(AF_UNIX, SOCK_STREAM, 0)
        guard link >= 0 else { throw failure() }
        defer { close(link) }
        var peer = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: peer.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        peer.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        peer.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &peer.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(link, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { throw failure() }
        // Darwin's cmsghdr is 12 bytes, 4-aligned, so one descriptor follows it at offset 12.
        let header = MemoryLayout<cmsghdr>.size
        var control = [UInt8](repeating: 0, count: header + MemoryLayout<Int32>.size)
        var byte: UInt8 = 0
        var flags: Int32 = 0
        let count = withUnsafeMutablePointer(to: &byte) { base in
            control.withUnsafeMutableBytes { buffer in
                var vector = iovec(iov_base: base, iov_len: 1)
                return withUnsafeMutablePointer(to: &vector) { vectors in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectors, msg_iovlen: 1,
                                         msg_control: buffer.baseAddress, msg_controllen: socklen_t(buffer.count),
                                         msg_flags: 0)
                    defer { flags = message.msg_flags }
                    return recvmsg(link, &message, 0)
                }
            }
        }
        guard count >= 0 else { throw failure() }
        let (length, level, type, fd) = control.withUnsafeBytes {
            ($0.load(as: UInt32.self), $0.load(fromByteOffset: 4, as: Int32.self),
             $0.load(fromByteOffset: 8, as: Int32.self), $0.load(fromByteOffset: header, as: Int32.self))
        }
        guard count > 0, flags & MSG_CTRUNC == 0, level == SOL_SOCKET, type == SCM_RIGHTS,
              Int(length) == control.count else { throw POSIXError(.EBADMSG) }
        return fd
    }

    private func serve() {
        defer {
            close(fd)
            close(wake[0])
            close(wake[1])
            done.signal()
        }
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var waiting = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            guard poll(&waiting, 2, -1) >= 0 || errno == EINTR else { return }
            if waiting[1].revents != 0 { return }
            guard waiting[0].revents & Int16(POLLIN) != 0 else { continue }
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &peerLength)
                }
            }
            guard count > 0 else { continue }
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
