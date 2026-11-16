import Darwin
import Foundation
import os
import TopoCore
import TopoUserland

/// Whether the turns' model requests go on a message thread, inferred from what each one uploaded:
/// nothing of the app's is between Claude Code and Anthropic, so no request is read, and what is
/// read is the counter of bytes sent (`TCP_CONNECTION_INFO`) on the guest's own connections to
/// Anthropic, which are the app's sockets. A request on a thread sends what is new since the last;
/// one carrying the whole conversation sends all of it. Set beside the context the request was sent
/// (its tokens, from the stream), that tells the two apart: a continue measured some 0.2 bytes a
/// token at Claude Code 2.1.316, a thread begun or a whole re-send 1.5 to 1.8 (compressed).
///
/// A request is the one connection to Anthropic that sent anything between the line before it and
/// its answer's start; when none did, or more than one (the event batch Claude Code sends to the
/// same host, a sub-agent's request alongside), the request is not told, and nothing is guessed.
/// Read only while a turn is in flight, on a queue of its own, and at the turn's moments alone: the
/// request has gone by the time it is read, so nothing waits on it. A note is a time, a count of
/// bytes, a count of tokens and a kind: no word, header value or id. In memory only, and the app
/// clears it when a login ends.
final class ThreadSampler: Sendable {
    enum Kind: String, Sendable, Equatable {
        /// A small upload for the context: only what was new went.
        case thread
        /// An upload the size of the context: the whole conversation went (a thread begun, or none).
        case whole
        /// Not told: no one connection's upload to read, or a ratio between the two.
        case unknown
    }

    struct Note: Sendable, Equatable {
        let at: Date
        /// What the request's connection sent, nil when it could not be told which one that was.
        let bytes: Int?
        let tokens: Int
        let kind: Kind
    }

    /// A socket as the counters are kept by: its descriptor and its inode, so a descriptor closed
    /// and opened again on another connection is another socket.
    struct Socket: Hashable, Sendable {
        let descriptor: Int32
        let inode: UInt64
    }

    static let shared = ThreadSampler()

    /// How many requests are kept, the newest last.
    static let kept = 20

    /// Bytes a token at or under which a request reads as on a thread, and at or over which it reads
    /// as the whole conversation; between them it is not told.
    static let threadAtMost = 0.5
    static let wholeAtLeast = 1.0

    /// The host whose connections are read.
    static let host = "api.anthropic.com"

    /// What a request of `tokens` that sent `bytes` was.
    static func kind(bytes: Int?, tokens: Int) -> Kind {
        guard let bytes, bytes > 0, tokens > 0 else { return .unknown }
        let ratio = Double(bytes) / Double(tokens)
        if ratio <= threadAtMost { return .thread }
        if ratio >= wholeAtLeast { return .whole }
        return .unknown
    }

    /// What the one connection that sent anything between `before` and `after` sent; nil when none
    /// did or more than one did. A socket not in `before` was opened since, and all it sent counts.
    static func upload(from before: [Socket: UInt64], to after: [Socket: UInt64]) -> Int? {
        let grew = after.compactMap { socket, sent -> UInt64? in
            let was = before[socket] ?? 0
            return sent > was ? sent - was : nil
        }
        return grew.count == 1 ? Int(grew[0]) : nil
    }

    private struct State {
        var notes: [Note] = []
        /// The counters at the last moment of the turn in flight; nil with none in flight.
        var mark: [Socket: UInt64]?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "zone.hexagon.topo.thread-sampler", qos: .utility)
    private let read: @Sendable () -> [Socket: UInt64]
    private let now: @Sendable () -> Date

    init(read: @escaping @Sendable () -> [Socket: UInt64] = { ThreadSampler.sockets(to: ThreadSampler.host) },
         now: @escaping @Sendable () -> Date = Date.init) {
        self.read = read
        self.now = now
    }

    /// A turn's moment, as the session tells it: read on the sampler's queue, so the session's
    /// actor never waits on a socket or a lookup.
    func heard(_ moment: GuestSession.RequestMoment) {
        queue.async { self.take(moment) }
    }

    /// Takes `moment` where it is called.
    func take(_ moment: GuestSession.RequestMoment) {
        switch moment {
        case .written:
            let counters = read()
            state.withLock { $0.mark = counters }
        case .answered(let subagent, let tokens):
            guard let before = state.withLock({ $0.mark }) else { return }
            let after = read()
            let bytes = Self.upload(from: before, to: after)
            let note = Note(at: now(), bytes: bytes, tokens: tokens, kind: Self.kind(bytes: bytes, tokens: tokens))
            state.withLock { state in
                guard state.mark != nil else { return }
                state.mark = after
                // A sub-agent's request is told by its own answer's start, but its upload ran beside
                // the turn's own: only the turn's requests are kept.
                guard !subagent else { return }
                state.notes.append(note)
                if state.notes.count > Self.kept { state.notes.removeFirst(state.notes.count - Self.kept) }
            }
            if !subagent { Perf.mark("turn.guest.upload kind=\(note.kind.rawValue) bytes=\(bytes.map(String.init) ?? "unknown")") }
        case .ended:
            state.withLock { $0.mark = nil }
        }
    }

    /// The requests kept, oldest first.
    func recent() -> [Note] { state.withLock { $0.notes } }

    /// Forgets every request: a login has ended.
    func clear() { state.withLock { $0 = State() } }

    // MARK: The counters

    /// Bytes sent so far on each of this process's TCP sockets whose peer is an address `host`
    /// resolves to, at port 443. Blocking: the lookup and the reads are the sampler queue's.
    static func sockets(to host: String) -> [Socket: UInt64] {
        sockets(addresses: addresses(of: host), port: 443)
    }

    /// Bytes sent so far on each of this process's TCP sockets whose peer is one of `addresses`
    /// at `port`.
    static func sockets(addresses: Set<String>, port: Int) -> [Socket: UInt64] {
        guard !addresses.isEmpty else { return [:] }
        var found: [Socket: UInt64] = [:]
        for descriptor in 0..<min(getdtablesize(), 4096) {
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
                  let peer = peer(of: descriptor), peer.port == port, addresses.contains(peer.address) else { continue }
            var info = tcp_connection_info()
            var length = socklen_t(MemoryLayout<tcp_connection_info>.size)
            guard getsockopt(descriptor, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &length) == 0 else { continue }
            found[Socket(descriptor: descriptor, inode: UInt64(status.st_ino))] = info.tcpi_txbytes
        }
        return found
    }

    /// The numeric addresses `host` resolves to, v4-mapped v6 written as v4.
    static func addresses(of host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found = Set<String>()
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            if let address = entry.pointee.ai_addr, let name = numeric(address, length: entry.pointee.ai_addrlen) {
                found.insert(name.address)
            }
            next = entry.pointee.ai_next
        }
        return found
    }

    private static func peer(of descriptor: Int32) -> (address: String, port: Int)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
        }
        guard got == 0 else { return nil }
        let size = socklen_t(storage.ss_len)
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { numeric($0, length: size) }
        }
    }

    private static func numeric(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> (address: String, port: Int)? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        guard getnameinfo(address, length, &host, socklen_t(host.count), &service, socklen_t(service.count),
                          NI_NUMERICHOST | NI_NUMERICSERV) == 0 else { return nil }
        var name = String(cString: host)
        if name.hasPrefix("::ffff:"), !name.dropFirst(7).contains(":") { name = String(name.dropFirst(7)) }
        return (name, Int(String(cString: service)) ?? 0)
    }
}
