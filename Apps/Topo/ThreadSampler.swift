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
/// The counters are read at three of a turn's moments, on a queue of its own, so nothing waits on
/// a read: when each of the turn's own requests begins answering, by which time it has gone, and
/// when the turn ends, which is the next turn's first baseline. A request's upload is what the one
/// connection that grew sent between the read before it and the read at its answer. It is not told
/// — and nothing is guessed — when none grew or more than one did (the event batch Claude Code
/// sends to the same host, a sub-agent's request alongside), when a connection read before is gone
/// at the answer (what it sent last is not known), when the read before it finished after the
/// request could have begun (after the turn's words were written, for its first; after the app
/// read the end of the answer before, for the rest), when a sub-agent's answer began since that
/// read, or when its own read finished after the app read its answer's end. Those times are when
/// the app read Claude Code's lines, so a request sent faster than the app reads them can be counted
/// short. Other than that, what is counted is never less than the request sent, only more (another
/// request on the same connection between the reads): a request said to be on a thread sent no more
/// than that, and one said to carry the whole conversation may be one that shared its connection.
///
/// A note is a time, a count of bytes, a count of tokens and a kind: no word, header value or id. In
/// memory only, and the app clears it when a login ends: a moment heard before the clear keeps
/// nothing, whenever its read runs.
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

    /// A socket as the counters are kept by: its descriptor and its local port, so a descriptor
    /// closed and opened again on another connection, which takes another port, is another socket
    /// (Darwin gives every socket an inode of 0, so the inode cannot tell them apart).
    struct Socket: Hashable, Sendable {
        let descriptor: Int32
        let port: Int
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
    /// did, more than one did, or one in `before` is gone from `after`. A socket not in `before` was
    /// opened since, and all it sent counts.
    static func upload(from before: [Socket: UInt64], to after: [Socket: UInt64]) -> Int? {
        guard before.keys.allSatisfy({ after[$0] != nil }) else { return nil }
        let grew = after.compactMap { socket, sent -> UInt64? in
            let was = before[socket] ?? 0
            return sent > was ? sent - was : nil
        }
        return grew.count == 1 ? Int(grew[0]) : nil
    }

    /// The counters as one moment read them, and when that read finished.
    private struct Reading {
        let counters: [Socket: UInt64]
        let at: UInt64
        /// Whether the request after it can be counted from it: the read finished before that
        /// request could have begun.
        var usable = false
    }

    /// `mark` made usable when its read finished before `moment`, after which the next request
    /// can begin; nil when it finished after, since that request may have been under way.
    private static func usable(_ mark: Reading?, before moment: UInt64) -> Reading? {
        guard var mark, mark.at < moment else { return nil }
        mark.usable = true
        return mark
    }

    /// A request of the turn's own whose answer has begun and not yet ended.
    private struct Open {
        let request: Int
        let tokens: Int
        let bytes: Int?
        let read: UInt64
        let at: Date
    }

    private struct State {
        var notes: [Note] = []
        /// Whether a turn is in flight.
        var inFlight = false
        /// The read the next request is counted from; nil when there is none it can be.
        var mark: Reading?
        var open: Open?
        /// Moved by every clear: a moment heard before one keeps nothing.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "zone.hexagon.topo.thread-sampler", qos: .utility)
    private let read: @Sendable () -> [Socket: UInt64]?
    private let now: @Sendable () -> Date
    private let ticks: @Sendable () -> UInt64

    init(read: @escaping @Sendable () -> [Socket: UInt64]? = { ThreadSampler.sockets(to: ThreadSampler.host) },
         now: @escaping @Sendable () -> Date = Date.init,
         ticks: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.read = read
        self.now = now
        self.ticks = ticks
    }

    /// A turn's moment, as the session tells it: stamped with when it was heard and under which
    /// login, then read on the sampler's queue, so the session's actor never waits on a socket or a
    /// lookup.
    func heard(_ moment: GuestSession.RequestMoment) {
        let generation = state.withLock { $0.generation }
        let at = ticks()
        queue.async { self.take(moment, heard: at, generation: generation) }
    }

    /// Waits for every moment heard so far to be taken (the suites').
    func settled() { queue.sync {} }

    private func take(_ moment: GuestSession.RequestMoment, heard: UInt64, generation: Int) {
        switch moment {
        case .written:
            update(generation) { state in
                state.inFlight = true
                state.open = nil
                state.mark = Self.usable(state.mark, before: heard)
            }
        case .answered(own: nil, _):
            update(generation) { state in if state.inFlight { state.mark = nil } }
        case .answered(own: let request?, let tokens):
            guard let before = current(generation, { $0.inFlight ? .some($0.mark) : nil }) else { return }
            let after = read()
            let at = ticks()
            let bytes = before.flatMap { before in
                before.usable ? after.flatMap { Self.upload(from: before.counters, to: $0) } : nil
            }
            let opened = Open(request: request, tokens: tokens, bytes: bytes, read: at, at: now())
            let unended = update(generation) { state -> Open? in
                guard state.inFlight else { return nil }
                let unended = state.open
                state.open = opened
                state.mark = after.map { Reading(counters: $0, at: at) }
                return unended
            } ?? nil
            if let unended { keep(unended, told: false, generation) }
        case .finished(own: false):
            break
        case .finished(own: true):
            let ended = update(generation) { state -> Open? in
                let open = state.open
                state.open = nil
                state.mark = Self.usable(state.mark, before: heard)
                return open
            } ?? nil
            if let ended { keep(ended, told: ended.read < heard, generation) }
        case .ended:
            let unended = update(generation) { state -> Open? in
                let open = state.open
                state.inFlight = false
                state.open = nil
                state.mark = nil
                return open
            } ?? nil
            if let unended { keep(unended, told: false, generation) }
            let after = read()
            let at = ticks()
            update(generation) { state in
                guard !state.inFlight else { return }
                state.mark = after.map { Reading(counters: $0, at: at) }
            }
        }
    }

    /// Keeps a request's note, its bytes only when `told`, and marks it for `topo perf` by its number.
    private func keep(_ open: Open, told: Bool, _ generation: Int) {
        let bytes = told ? open.bytes : nil
        let note = Note(at: open.at, bytes: bytes, tokens: open.tokens, kind: Self.kind(bytes: bytes, tokens: open.tokens))
        let kept = update(generation) { state -> Bool in
            state.notes.append(note)
            if state.notes.count > Self.kept { state.notes.removeFirst(state.notes.count - Self.kept) }
            return true
        } ?? false
        if kept {
            Perf.mark("turn.guest.upload request=\(open.request) kind=\(note.kind.rawValue) bytes=\(bytes.map(String.init) ?? "unknown")")
        }
    }

    /// Runs `body` on the state if no clear has landed since `generation`; nil when one has.
    @discardableResult
    private func update<T>(_ generation: Int, _ body: (inout State) -> T) -> T? {
        state.withLockUnchecked { state in state.generation == generation ? body(&state) : nil }
    }

    private func current<T>(_ generation: Int, _ body: (State) -> T?) -> T? {
        state.withLockUnchecked { state in state.generation == generation ? body(state) : nil }
    }

    /// The requests kept, oldest first.
    func recent() -> [Note] { state.withLock { $0.notes } }

    /// Forgets every request: a login has ended. A moment heard before it keeps nothing, whether it
    /// is still queued or still reading.
    func clear() { state.withLock { $0 = State(generation: $0.generation + 1) } }

    // MARK: The counters

    /// Bytes sent so far on each of this process's TCP sockets whose peer is an address `host`
    /// resolves to, at port 443; nil when the name resolves to nothing, since an empty answer
    /// would make the next read count each connection's whole life. Blocking: the lookup and the
    /// reads are the sampler queue's.
    static func sockets(to host: String) -> [Socket: UInt64]? {
        let addresses = addresses(of: host)
        return addresses.isEmpty ? nil : sockets(addresses: addresses, port: 443)
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
            guard let local = local(of: descriptor) else { continue }
            found[Socket(descriptor: descriptor, port: local)] = info.tcpi_txbytes
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

    private static func local(of descriptor: Int32) -> Int? {
        name(of: descriptor, by: getsockname)?.port
    }

    private static func peer(of descriptor: Int32) -> (address: String, port: Int)? {
        name(of: descriptor, by: getpeername)
    }

    private static func name(of descriptor: Int32,
                             by call: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32)
        -> (address: String, port: Int)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let got = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(descriptor, $0, &length) }
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
        var name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasPrefix("::ffff:"), !name.dropFirst(7).contains(":") { name = String(name.dropFirst(7)) }
        return (name, Int(String(decoding: service.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) ?? 0)
    }
}
