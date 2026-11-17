import TopoUserland
import XCTest

@testable import Topo

/// What `topo context threads` reads with nothing of the app's between Claude Code and
/// Anthropic: each request's upload from the connection's counters, against its context.
final class ThreadSamplerTests: XCTestCase {
    private typealias Socket = ThreadSampler.Socket

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

    /// The most any connection that grew sent, and whether one alone did; none, or one gone since
    /// the read before, is not told; a socket opened since counts whole, and a descriptor opened again
    /// on another connection is another socket.
    func testAnUploadIsWhatTheConnectionsThatGrewSent() {
        typealias Upload = ThreadSampler.Upload
        XCTAssertEqual(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [messages: 2_700, telemetry: 50]),
                       Upload(bytes: 2_600, alone: true))
        XCTAssertEqual(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [messages: 2_700, telemetry: 900]),
                       Upload(bytes: 2_600, alone: false), "the larger of two that grew, the request's, said not to be alone")
        XCTAssertEqual(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [messages: 2_700, telemetry: 8_450]),
                       Upload(bytes: 8_400, alone: false), "the larger of two that grew, another connection's, as the bound")
        XCTAssertNil(ThreadSampler.upload(from: [messages: 100], to: [messages: 100]))
        XCTAssertEqual(ThreadSampler.upload(from: [:], to: [messages: 21_000]), Upload(bytes: 21_000, alone: true))
        let again = Socket(descriptor: 21, port: 52_140)
        XCTAssertNil(ThreadSampler.upload(from: [messages: 30_000], to: [again: 1_200]), "the old connection's last sends are not known")
        XCTAssertEqual(ThreadSampler.upload(from: [telemetry: 50], to: [telemetry: 50, again: 1_200]), Upload(bytes: 1_200, alone: true))
        XCTAssertNil(ThreadSampler.upload(from: [messages: 100, telemetry: 50], to: [telemetry: 900]),
                     "a connection gone between the reads may have sent too")
    }

    /// The most of several connections is an upper bound: small even so is a thread, and large is not
    /// told, never the whole conversation (the paced run at 938ee637: 2.6 KB of the request's beside
    /// 8 KB of a second connection's, for 60,000 tokens).
    func testASharedUploadCanSayAThreadAndNeverTheWholeConversation() {
        XCTAssertEqual(ThreadSampler.kind(bytes: 8_400, tokens: 60_400, shared: true), .thread)
        XCTAssertEqual(ThreadSampler.kind(bytes: 41_000, tokens: 60_400, shared: true), .unknown, "between the two")
        XCTAssertEqual(ThreadSampler.kind(bytes: 90_000, tokens: 60_400, shared: true), .unknown, "a sum read as the whole conversation")
        XCTAssertEqual(ThreadSampler.kind(bytes: 90_000, tokens: 60_400), .whole)
    }

    /// A clock that moves on at every reading, so each moment is heard after the last read finished.
    private final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.withLock { value += 1; return value } }
    }

    /// A reader the test can stall: `hold()` makes the next read wait until `let()`, and every read
    /// is counted.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Socket: UInt64]? = [:]
        private var held = false
        private var count = 0
        let reading = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var now: [Socket: UInt64]? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        var reads: Int { lock.withLock { count } }
        func hold() { lock.withLock { held = true } }
        func `let`() { released.signal() }
        func read() -> [Socket: UInt64]? {
            let stall = lock.withLock { () -> Bool in
                count += 1
                defer { held = false }
                return held
            }
            if stall { reading.signal(); released.wait() }
            return now
        }
    }

    private let at = Date(timeIntervalSince1970: 1_000)

    private func sampler(_ reader: Reader) -> ThreadSampler {
        let ticks = Ticks()
        let at = at
        return ThreadSampler(read: { reader.read() }, now: { at }, ticks: { ticks.next() })
    }

    /// One request of the turn's own, its answer begun and, once its read is done, ended.
    private func request(_ sampler: ThreadSampler, _ number: Int, tokens: Int) {
        sampler.heard(.answered(own: number, tokens: tokens))
        sampler.settled()
        sampler.heard(.finished(own: true))
    }

    /// A turn's moments: what each of its own requests uploaded since the read before it, the
    /// first counted from the read at the last turn's end, a sub-agent's request kept out, and all
    /// of it forgotten at a login's end.
    func testATurnsRequestsAreNotedAndClearedAtALoginsEnd() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 500, telemetry: 40]
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 1))
        reader.now = [messages: 21_500, telemetry: 40]
        request(sampler, 1, tokens: 12_800)
        sampler.settled()
        reader.now = [messages: 24_100, telemetry: 40]
        request(sampler, 2, tokens: 13_300)
        sampler.settled()
        sampler.heard(.ended)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: 21_000, tokens: 12_800, kind: .whole),
            .init(at: at, bytes: 2_600, tokens: 13_300, kind: .thread),
        ])
        sampler.clear()
        XCTAssertEqual(sampler.recent(), [])
    }

    /// A second connection that sends between turns (as one did on the simulator at 938ee637, some
    /// 8 KB a turn) leaves the request's upload bounded by the larger of the two: a thread still, said
    /// as at most, and a bound too large for one is not told rather than the whole conversation.
    func testASecondConnectionSendingBetweenTurnsLeavesAnUpperBound() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 71_400, telemetry: 46_700]
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 3))
        reader.now = [messages: 80_400, telemetry: 55_100]
        request(sampler, 1, tokens: 60_400)
        sampler.settled()
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 4))
        reader.now = [messages: 116_400, telemetry: 63_500]
        request(sampler, 1, tokens: 60_500)
        sampler.settled()
        sampler.heard(.ended)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: 9_000, tokens: 60_400, kind: .thread, shared: true),
            .init(at: at, bytes: 36_000, tokens: 60_500, kind: .unknown, shared: true),
        ])
    }

    /// The first turn after a launch or a login has no read before it, so its first request is
    /// not told; one counted from a read at its turn's end is.
    func testAFirstRequestWithNoReadBeforeItIsNotTold() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 21_000]
        sampler.heard(.written(turn: 1))
        request(sampler, 1, tokens: 12_800)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [.init(at: at, bytes: nil, tokens: 12_800, kind: .unknown)])
    }

    /// A sub-agent's answer begun between two of the turn's requests leaves the second not told:
    /// its upload may have run beside the turn's own, so no read in between is a baseline.
    func testASubagentsAnswerLeavesTheNextRequestNotTold() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 500]
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 1))
        reader.now = [messages: 21_500]
        sampler.heard(.answered(own: 1, tokens: 12_800))
        sampler.settled()
        reader.now = [messages: 42_500]
        sampler.heard(.answered(own: nil, tokens: 13_000))
        sampler.heard(.finished(own: false))
        sampler.heard(.finished(own: true))
        reader.now = [messages: 43_500]
        request(sampler, 2, tokens: 13_300)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: 21_000, tokens: 12_800, kind: .whole),
            .init(at: at, bytes: nil, tokens: 13_300, kind: .unknown),
        ])
    }

    /// A read that finished after the request it is the baseline of could have begun is no
    /// baseline: the turn's end read late, past the next turn's words, leaves that turn's first
    /// request not told rather than counted short.
    func testABaselineReadLateLeavesTheNextRequestNotTold() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 500]
        reader.hold()
        sampler.heard(.ended)
        reader.reading.wait()
        sampler.heard(.written(turn: 1))
        reader.now = [messages: 20_500]
        reader.let()
        reader.now = [messages: 21_500]
        request(sampler, 1, tokens: 12_800)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [.init(at: at, bytes: nil, tokens: 12_800, kind: .unknown)])
    }

    /// A request's own read that finished after the app read its answer's end may have counted the
    /// next request's upload in it: it is not told, and nor is the next, which it was the baseline of.
    func testAnAnswersReadLatePastItsEndIsNotTold() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 500]
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 1))
        sampler.settled()
        reader.now = [messages: 21_500]
        reader.hold()
        sampler.heard(.answered(own: 1, tokens: 12_800))
        reader.reading.wait()
        sampler.heard(.finished(own: true))
        reader.now = [messages: 22_500]
        reader.let()
        reader.now = [messages: 24_100]
        request(sampler, 2, tokens: 13_300)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: nil, tokens: 12_800, kind: .unknown),
            .init(at: at, bytes: nil, tokens: 13_300, kind: .unknown),
        ])
    }

    /// A clear keeps nothing heard before it: a moment still reading when it lands, and a later
    /// turn's moments queued behind that read, whatever they read.
    func testMomentsHeardBeforeALoginEndsKeepNothing() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = [messages: 500]
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 1))
        sampler.settled()
        reader.hold()
        sampler.heard(.answered(own: 1, tokens: 12_800))
        reader.reading.wait()
        sampler.heard(.finished(own: true))
        sampler.heard(.ended)
        sampler.heard(.written(turn: 1))
        sampler.heard(.answered(own: 1, tokens: 13_000))
        sampler.heard(.finished(own: true))
        sampler.heard(.ended)
        sampler.clear()
        reader.now = [messages: 21_500]
        reader.let()
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [])
        // And the next login's first turn starts from nothing of the last's.
        sampler.heard(.written(turn: 1))
        reader.now = [messages: 24_100]
        request(sampler, 1, tokens: 13_300)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [.init(at: at, bytes: nil, tokens: 13_300, kind: .unknown)])
    }

    /// A lookup that failed is no baseline: the request after it is not told, rather than counting
    /// each connection's whole life, and the next one is read from the counters that did come.
    func testAFailedReadLeavesTheNextRequestNotTold() {
        let reader = Reader()
        let sampler = sampler(reader)
        reader.now = nil
        sampler.heard(.ended)
        sampler.settled()
        sampler.heard(.written(turn: 1))
        reader.now = [messages: 90_000]
        request(sampler, 1, tokens: 30_000)
        reader.now = [messages: 92_600]
        request(sampler, 2, tokens: 31_000)
        reader.now = nil
        request(sampler, 3, tokens: 32_000)
        sampler.settled()
        XCTAssertEqual(sampler.recent(), [
            .init(at: at, bytes: nil, tokens: 30_000, kind: .unknown),
            .init(at: at, bytes: 2_600, tokens: 31_000, kind: .thread),
            .init(at: at, bytes: nil, tokens: 32_000, kind: .unknown),
        ])
    }

    /// Between a turn's end and its next words nothing is read: an answer heard then reads no counter
    /// and keeps nothing.
    func testNothingIsReadBetweenTurns() {
        let reader = Reader()
        let sampler = sampler(reader)
        sampler.heard(.ended)
        sampler.settled()
        let reads = reader.reads
        request(sampler, 1, tokens: 13_400)
        sampler.settled()
        XCTAssertEqual(reader.reads, reads, "a moment between turns read the counters")
        XCTAssertEqual(sampler.recent(), [])
    }

    /// A note is its time, bytes, tokens, kind and whether more than one connection sent, and nothing
    /// else: no word, header or id.
    func testANoteHoldsNothingButTimeBytesTokensAndKind() {
        let note = ThreadSampler.Note(at: Date(), bytes: 1, tokens: 2, kind: .thread)
        XCTAssertEqual(Mirror(reflecting: note).children.compactMap(\.label), ["at", "bytes", "tokens", "kind", "shared"])
    }

    func testOnlyTheLastTwentyAreKept() {
        let reader = Reader()
        let sampler = sampler(reader)
        sampler.heard(.written(turn: 1))
        for n in 1...25 {
            reader.now = [messages: UInt64(n * 1_000)]
            request(sampler, n, tokens: n)
        }
        sampler.settled()
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

    /// A descriptor closed and taken again by the next connection is another socket, never the
    /// difference from the old one's count: the old one is gone between the reads, so nothing is told.
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
        // The next connection takes the very descriptor the first had: `dup2` closes the first and
        // puts the new one in its place in one call, so no other thread can take it between.
        let (fresh, secondPeer) = connected()
        XCTAssertEqual(dup2(fresh, first), first)
        close(fresh)
        let second = first
        defer { close(second); close(secondPeer) }
        let secondIn = received(160_000, at: secondPeer)
        send(160_000, on: second)
        XCTAssertEqual(secondIn.wait(timeout: .now() + 5), .success)
        let after = ThreadSampler.sockets(addresses: ["127.0.0.1"], port: port)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.keys.first?.descriptor, before.keys.first?.descriptor, "the descriptor was not taken again")
        XCTAssertNotEqual(after.keys.first, before.keys.first, "a new connection on the descriptor read as the old one")
        XCTAssertEqual(after.values.first, 160_000)
        XCTAssertNil(ThreadSampler.upload(from: before, to: after),
                     "the old connection is gone, so what it sent last is not known and nothing is counted")
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
