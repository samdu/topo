import Foundation
import TopoProxy
import TopoTools
import TopoUserland
import XCTest

/// The guest's DNS stub in the booted guest (`patches/ish/0006-dns-sentinel.patch`): `127.0.0.53`
/// port 53 carried to `127.0.0.1` at the port the app set and reported back as the stub, nothing
/// else touched, and musl resolving through the app's forwarder end to end. The addresses are what
/// the guest's calls returned (`Tests/Programs/dnsaddr.c`); the lookups are musl's own
/// (`Tests/Programs/resolve.c`). Nothing here reaches past loopback.
final class GuestDNSTests: XCTestCase {
    nonisolated(unsafe) private static var programs: String?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
        if Self.programs == nil { Self.programs = try Self.mountPrograms() }
    }

    override func tearDown() async throws {
        Guest.shared.setDNSPort(nil)
    }

    /// Both programs, mounted from a copy the guest may execute.
    private static func mountPrograms() throws -> String {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs")
        let dir = fm.temporaryDirectory.appendingPathComponent("dns-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["dnsaddr", "resolve"] {
            let copy = dir.appendingPathComponent(name)
            try fm.copyItem(at: source.appendingPathComponent(name), to: copy)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        }
        let point = "/opt/dns-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)
        return point
    }

    private func run(_ program: String, _ arguments: [String]) async throws -> String {
        let exit = try await Guest.shared.run("\(Self.programs!)/\(program)", arguments)
        XCTAssertEqual(exit.errors, "")
        return exit.output
    }

    /// What `dnsaddr udp` reported for each call, by name.
    private func addresses(_ family: String, _ host: String, _ port: UInt16) async throws -> [String: String] {
        let line = try await run("dnsaddr", ["udp", family, host, String(port)])
        var fields: [String: String] = [:]
        var key: String?
        for word in line.trimmingCharacters(in: .newlines).split(separator: " ") {
            if let equals = word.firstIndex(of: "=") {
                key = String(word[..<equals])
                fields[key!] = String(word[word.index(after: equals)...])
            } else if let key {
                fields[key]! += " " + word
            }
        }
        return fields
    }

    /// For each family, the stub's address as the named call returned it, while the rewrite
    /// carries the stub to a server standing in for the forwarder.
    private func sentinel(_ call: String) async throws {
        let stub = try StubDNS(address: [10, 1, 2, 3])
        defer { stub.stop() }
        Guest.shared.setDNSPort(stub.port)
        let v4 = try await addresses("4", "127.0.0.53", 53)
        XCTAssertEqual(v4[call], "4 127.0.0.53 53", "\(v4)")
        let v6 = try await addresses("6", "::ffff:127.0.0.53", 53)
        XCTAssertEqual(v6[call], "6 ::ffff:127.0.0.53 53", "\(v6)")
        XCTAssertEqual(v4["reply"], "1")
        XCTAssertEqual(v6["reply"], "1")
    }

    // MARK: Review focus 6

    func testRecvfromSourceIsSentinel() async throws { try await sentinel("recvfrom") }

    func testRecvmsgSourceIsSentinel() async throws { try await sentinel("recvmsg") }

    func testGetpeernameIsSentinel() async throws { try await sentinel("getpeername") }

    /// Another loopback port is reported as itself, a TCP connect included, and the stub's address
    /// at a port other than 53 is not carried anywhere.
    func testOtherLoopbackPortsUntouched() async throws {
        let stub = try StubDNS(address: [10, 1, 2, 3])
        let other = try StubDNS(address: [10, 4, 5, 6])
        defer { stub.stop(); other.stop() }
        Guest.shared.setDNSPort(stub.port)
        let seen = try await addresses("4", "127.0.0.1", other.port)
        XCTAssertEqual(seen, ["recvfrom": "4 127.0.0.1 \(other.port)", "recvmsg": "4 127.0.0.1 \(other.port)",
                              "getpeername": "4 127.0.0.1 \(other.port)", "reply": "1"])
        XCTAssertEqual(stub.queries, 0)

        let service = try ToolService(tools: [])
        let toolPort = try await service.start()
        let connected = try await run("dnsaddr", ["tcp", "4", "127.0.0.1", String(toolPort)])
        await service.stop()
        XCTAssertEqual(connected, "getpeername=4 127.0.0.1 \(toolPort)\n")

        let elsewhere = try await addresses("4", "127.0.0.53", 5353)
        XCTAssertEqual(elsewhere["getpeername"], "4 127.0.0.53 5353")
        XCTAssertEqual(elsewhere["recvfrom"], "none")
        XCTAssertEqual(stub.queries, 0)
    }

    /// With no port set, the stub is an address nothing answers on, and the port that would have
    /// been the forwarder's is reported as itself.
    func testNoRewriteWithoutPort() async throws {
        let stub = try StubDNS(address: [10, 1, 2, 3])
        defer { stub.stop() }
        Guest.shared.setDNSPort(nil)
        let stubbed = try await addresses("4", "127.0.0.53", 53)
        XCTAssertEqual(stubbed["recvfrom"], "none")
        XCTAssertEqual(stubbed["recvmsg"], "none")
        XCTAssertEqual(stubbed["reply"], "none")
        XCTAssertEqual(stub.queries, 0)
        let direct = try await addresses("4", "127.0.0.1", stub.port)
        XCTAssertEqual(direct["recvfrom"], "4 127.0.0.1 \(stub.port)")
        XCTAssertEqual(direct["getpeername"], "4 127.0.0.1 \(stub.port)")
    }

    // MARK: musl through the forwarder

    /// A forwarder of the app's own, over a resolver that answers for `.example` names from a
    /// table, with the guest's rewrite given its port and the resolver file its stub.
    private func forwarder(_ table: [String: [UInt16: [RecordAnswer]]]) async throws -> DNSForwarder {
        let forwarder = DNSForwarder(resolver: TableResolver(table), log: { _ in })
        let port = try await forwarder.start()
        Guest.shared.setDNSPort(port)
        try await Guest.shared.writeResolver(servers: [Guest.dnsStub])
        return forwarder
    }

    func testMuslAcceptsReply() async throws {
        let forwarder = try await forwarder([
            "svc.example.": [1: [record("svc.example.", 1, [10, 9, 8, 7])],
                             28: [RecordAnswer(outcome: .noSuchRecord, name: "svc.example.", type: 28)],
                             16: [record("svc.example.", 16, [5] + Array("hello".utf8))]],
        ])
        defer { Task { await forwarder.stop() } }
        let resolved = try await run("resolve", ["svc.example"])
        XCTAssertEqual(resolved, "A 10.9.8.7\n")
        let text = try await run("resolve", ["-txt", "svc.example"])
        XCTAssertTrue(text.hasPrefix("TXT hello\nbytes "), text)
        let missing = try await run("resolve", ["gone.example"])
        XCTAssertTrue(missing.hasPrefix("gai "), missing)
    }

    /// A reply too large for a datagram comes back truncated, and musl asks again over TCP.
    func testTruncatedAnswerIsFetchedOverTCP() async throws {
        let strings = (0..<20).map { index in [UInt8(60)] + Array((String(format: "%02d", index) + String(repeating: "x", count: 58)).utf8) }
        let answers = strings.enumerated().map { index, data in
            RecordAnswer(outcome: .record, moreComing: index < strings.count - 1, name: "big.example.", type: 16,
                         ttl: 60, rdata: data)
        }
        let forwarder = try await forwarder(["big.example.": [16: answers]])
        defer { Task { await forwarder.stop() } }
        let text = try await run("resolve", ["-txt", "big.example"])
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("TXT ") }.count, 20, text)
        let bytes = Int(lines.last?.split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThan(bytes, 512)
    }

    /// Review focus 3, in the guest: a lookup resolves through the forwarder; the forwarder
    /// stops, the rewrite is cleared and the phone's servers written, as `GuestResolver` does on
    /// the phone; and the next lookup resolves through the server standing in for the phone's.
    func testLookupSurvivesForwarderStop() async throws {
        let phone = try StubDNS(address: [10, 7, 7, 7], onPort53: true)
        defer { phone.stop() }
        let forwarder = try await forwarder(["svc.example.": [1: [record("svc.example.", 1, [10, 9, 8, 7])],
                                                             28: [RecordAnswer(outcome: .noSuchRecord)]]])
        let down = expectation(description: "the forwarder went down")
        await forwarder.observe { port in
            guard port == nil else { return }
            Guest.shared.setDNSPort(nil)
            Task {
                try await Guest.shared.writeResolver(servers: ["127.0.0.1"])
                down.fulfill()
            }
        }
        let first = try await run("resolve", ["svc.example"])
        XCTAssertEqual(first, "A 10.9.8.7\n")
        await forwarder.stop()
        await fulfillment(of: [down], timeout: 10)
        let resolver = try await Guest.shared.run("/bin/cat", ["/etc/resolv.conf"])
        XCTAssertEqual(resolver.output, "nameserver 127.0.0.1\n")
        let second = try await run("resolve", ["svc.example"])
        XCTAssertEqual(second, "A 10.7.7.7\n")
        XCTAssertGreaterThan(phone.queries, 0)
    }

    private func record(_ name: String, _ type: UInt16, _ rdata: [UInt8]) -> RecordAnswer {
        RecordAnswer(outcome: .record, name: name, type: type, ttl: 60, rdata: rdata)
    }
}

/// Answers a question from a table by name and type — each callback delivered at once, in order —
/// and a name it does not hold with `NoSuchName`.
private struct TableResolver: RecordResolver {
    let table: [String: [UInt16: [RecordAnswer]]]
    init(_ table: [String: [UInt16: [RecordAnswer]]]) { self.table = table }

    func query(name: String, type: UInt16, queue: DispatchSerialQueue,
               answer: @escaping @Sendable (RecordAnswer) -> Void) -> any ResolverQuery {
        let handle = Handle()
        let answers = table[name.lowercased()].map { $0[type] ?? [RecordAnswer(outcome: .noSuchRecord)] }
            ?? [RecordAnswer(outcome: .noSuchName)]
        queue.async {
            for item in answers where !handle.cancelled { answer(item) }
        }
        return handle
    }

    final class Handle: ResolverQuery, @unchecked Sendable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
}
