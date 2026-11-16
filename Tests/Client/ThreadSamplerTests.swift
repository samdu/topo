import TopoUserland
import XCTest

@testable import Topo

/// What `topo context threads` reads with nothing of the app's between Claude Code and
/// Anthropic: each request's upload from the connection's counters, against its context.
final class ThreadSamplerTests: XCTestCase {
    private typealias Socket = ThreadSampler.Socket

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Socket: UInt64] = [:]
        var now: [Socket: UInt64] {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private let messages = Socket(descriptor: 21, port: 52_100)
    private let telemetry = Socket(descriptor: 22, port: 52_101)

    /// The spike's measured requests (Claude Code 2.1.316, simulator): a create, a continue and a
    /// whole re-send with threads off, each by its compressed upload against its context.
    func testTheMeasuredRequestsAreToldApart() {
        XCTAssertEqual(ThreadSampler.kind(bytes: 21_000, tokens: 12_800), .whole, "a thread begun")
        XCTAssertEqual(ThreadSampler.kind(bytes: 2_600, tokens: 13_300), .thread, "a thread continued")
        XCTAssertEqual(ThreadSampler.kind(bytes: 16_100, tokens: 9_800), .whole, "threads off")
        XCTAssertEqual(ThreadSampler.kind(bytes: 9_000, tokens: 12_000), .unknown, "between the two")
        XCTAssertEqual(ThreadSampler.kind(bytes: nil, tokens: 12_000), .unknown)
        XCTAssertEqual(ThreadSampler.kind(bytes: 2_600, tokens: 0), .unknown)
    }

    /// One connection that grew is the request's; none, or two, is not told; a socket opened since
    /// counts whole, and a descriptor opened again on another connection is another socket.
    func testAnUploadIsTheOneConnectionThatGrew() {
        XCTAssertEqual(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [messages: 2_700, telemetry: 50]), 2_600)
        XCTAssertNil(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [messages: 2_700, telemetry: 900]))
        XCTAssertNil(ThreadSampler.upload(from: [messages: 100], to: [messages: 100]))
        XCTAssertEqual(ThreadSampler.upload(from: [:], to: [messages: 21_000]), 21_000)
        let again = Socket(descriptor: 21, port: 52_140)
        XCTAssertEqual(ThreadSampler.upload(from: [messages: 30_000], to: [again: 1_200]), 1_200)
    }

    /// A turn's moments: what each of its own requests uploaded since the line before it, a
    /// sub-agent's request kept out, nothing read once the turn has ended, and all of it forgotten
    /// at a login's end.
    func testATurnsRequestsAreNotedAndClearedAtALoginsEnd() {
        let counters = Counters()
        let at = Date(timeIntervalSince1970: 1_000)
        let sampler = ThreadSampler(read: { counters.now }, now: { at })
        counters.now = [messages: 500, telemetry: 40]
        sampler.take(.written)
        counters.now = [messages: 21_500, telemetry: 40]
        sampler.take(.answered(subagent: false, tokens: 12_800))
        counters.now = [messages: 22_000, telemetry: 40]
        sampler.take(.answered(subagent: true, tokens: 3_000))
        counters.now = [messages: 24_600, telemetry: 40]
        sampler.take(.answered(subagent: false, tokens: 13_300))
        sampler.take(.ended)
        counters.now = [messages: 90_000, telemetry: 40]
        sampler.take(.answered(subagent: false, tokens: 13_400))
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: 21_000, tokens: 12_800, kind: .whole),
            .init(at: at, bytes: 2_600, tokens: 13_300, kind: .thread),
        ])
        sampler.clear()
        XCTAssertEqual(sampler.recent(), [])
    }

    /// A clear that lands while a moment is still reading the counters (a lookup that stalled, say)
    /// leaves nothing behind it: the read lands under a login that has ended and is dropped.
    func testAReadUnderWayWhenALoginEndsKeepsNothing() {
        let counters = Counters()
        let reading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let stall = Counters()
        stall.now = [messages: 1]
        let messages = messages
        let sampler = ThreadSampler(read: {
            if stall.now[messages] == 1 { reading.signal(); release.wait() }
            return counters.now
        })
        counters.now = [messages: 500]
        let written = expectation(description: "written")
        DispatchQueue.global().async { sampler.take(.written); written.fulfill() }
        reading.wait()
        sampler.clear()
        stall.now = [:]
        release.signal()
        wait(for: [written], timeout: 5)
        counters.now = [messages: 21_500]
        sampler.take(.answered(subagent: false, tokens: 12_800))
        XCTAssertEqual(sampler.recent(), [])

        counters.now = [messages: 30_000]
        sampler.take(.written)
        stall.now = [messages: 1]
        let answered = expectation(description: "answered")
        DispatchQueue.global().async { sampler.take(.answered(subagent: false, tokens: 13_000)); answered.fulfill() }
        reading.wait()
        sampler.clear()
        stall.now = [:]
        counters.now = [messages: 32_600]
        release.signal()
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(sampler.recent(), [])
    }

    /// A note is its time, bytes, tokens and kind, and nothing else: no word, header or id.
    func testANoteHoldsNothingButTimeBytesTokensAndKind() {
        let note = ThreadSampler.Note(at: Date(), bytes: 1, tokens: 2, kind: .thread)
        XCTAssertEqual(Mirror(reflecting: note).children.compactMap(\.label), ["at", "bytes", "tokens", "kind"])
    }

    func testOnlyTheLastTwentyAreKept() {
        let counters = Counters()
        let sampler = ThreadSampler(read: { counters.now })
        sampler.take(.written)
        for n in 1...25 {
            counters.now = [messages: UInt64(n * 1_000)]
            sampler.take(.answered(subagent: false, tokens: n))
        }
        XCTAssertEqual(sampler.recent().count, ThreadSampler.kept)
        XCTAssertEqual(sampler.recent().last?.tokens, 25)
    }

    /// The counters are read off this process's own sockets: a connection the test opens to a
    /// listener on the loopback, named by its address, is found with what it sent.
    func testTheCountersAreReadOffThisProcessesSockets() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(listener, $0, length) == 0, listen(listener, 1) == 0, getsockname(listener, $0, &length) == 0 else {
                    throw POSIXError(.EADDRINUSE)
                }
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let accepted = accept(listener, nil, nil)
        defer { close(accepted) }
        let bytes = [UInt8](repeating: 7, count: 1_234)
        XCTAssertEqual(write(client, bytes, bytes.count), 1_234)
        let found = ThreadSampler.sockets(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertEqual(found.first?.key.descriptor, client)
        XCTAssertEqual(found.first?.value, 1_234)
    }

    /// A descriptor closed and taken again by the next connection is another socket: what the new
    /// connection sent is the whole of its upload, not the difference from the old one's count.
    func testADescriptorTakenAgainByANewConnectionIsAnotherSocket() throws {
        let (listener, address, port) = try listening()
        defer { close(listener) }
        func connected() -> (Int32, Int32) {
            var to = address
            let client = socket(AF_INET, SOCK_STREAM, 0)
            let done = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            XCTAssertEqual(done, 0)
            return (client, accept(listener, nil, nil))
        }
        func send(_ count: Int, on client: Int32) {
            let bytes = [UInt8](repeating: 7, count: count)
            var sent = 0
            while sent < count {
                let wrote = bytes.withUnsafeBytes { write(client, $0.baseAddress! + sent, count - sent) }
                guard wrote > 0 else { return XCTFail("write \(errno)") }
                sent += wrote
            }
        }
        /// Signals once `count` bytes have arrived at `peer`, so its sender's count is settled.
        func received(_ count: Int, at peer: Int32) -> DispatchSemaphore {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 65_536), total = 0
                while total < count { let got = read(peer, &buffer, buffer.count); guard got > 0 else { break }; total += got }
                done.signal()
            }
            return done
        }
        let (first, firstPeer) = connected()
        defer { close(firstPeer) }
        let firstIn = received(150_000, at: firstPeer)
        send(150_000, on: first)
        XCTAssertEqual(firstIn.wait(timeout: .now() + 5), .success)
        let before = ThreadSampler.sockets(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(before.values.first, 150_000)
        close(first)
        let (second, secondPeer) = connected()
        defer { close(second); close(secondPeer) }
        XCTAssertEqual(second, first, "the lowest free descriptor is taken again")
        let secondIn = received(160_000, at: secondPeer)
        send(160_000, on: second)
        XCTAssertEqual(secondIn.wait(timeout: .now() + 5), .success)
        let after = ThreadSampler.sockets(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(ThreadSampler.upload(from: before, to: after), 160_000)
    }

    private func listening() throws -> (Int32, sockaddr_in, Int) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(listener, $0, length) == 0, listen(listener, 2) == 0, getsockname(listener, $0, &length) == 0 else {
                    close(listener)
                    throw POSIXError(.EADDRINUSE)
                }
            }
        }
        return (listener, address, Int(UInt16(bigEndian: address.sin_port)))
    }
}
