import Foundation
import Testing
@testable import TopoProxy

/// The guest's name server over a scripted resolver: every bound, the completion and negative
/// rules, loopback alone, and a log of counts. Serialized: the clients here block on sockets.
@Suite(.serialized) struct DNSForwarderTests {
    // MARK: Review focus 1

    @Test func boundToLoopbackOnly() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        #expect(try udp(port: port, query(1, "x.example")) != nil)
        #expect(try tcp(port: port, [query(2, "x.example")]).count == 1)
        let addresses = nonLoopbackIPv4Addresses()
        try #require(!addresses.isEmpty, "this machine has no non-loopback IPv4 address to try")
        for address in addresses {
            #expect(try udp(port: port, query(3, "x.example"), host: address, wait: 0.5) == nil,
                    "\(address):\(port) answered a datagram")
            #expect(tcpConnect(host: address, port: port) == ECONNREFUSED, "\(address):\(port) accepted a connection")
        }
        #expect(resolver.asked.count == 2)
    }

    // MARK: Review focus 2

    @Test func oversizeQueryDropped() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        // A well-formed question padded past 512 bytes with an OPT record's data.
        let big = query(1, "x.example", edns: 1232, optPadding: 513 - query(1, "x.example", edns: 1232).count)
        #expect(big.count == 513)
        #expect(try udp(port: port, big, wait: 0.5) == nil)
        #expect(try tcpClosedAfter(port: port, lengthPrefix: 513))
        #expect(resolver.asked.isEmpty)
        // The same question at 512 bytes is asked.
        let fits = query(2, "x.example", edns: 1232, optPadding: 512 - query(2, "x.example", edns: 1232).count)
        #expect(fits.count == 512)
        #expect(try udp(port: port, fits) != nil)
        #expect(resolver.asked.count == 1)
    }

    @Test func inFlightCapAnswersServfail() async throws {
        let resolver = ScriptedResolver { _, _ in [] }
        let (forwarder, port) = try await started(resolver, queryBound: .seconds(30))
        defer { Task { await forwarder.stop() } }
        let client = try UDPClient(port: port)
        defer { client.close() }
        for id in 0..<64 { try client.send(query(UInt16(id), "slow\(id).example")) }
        try await eventually { resolver.asked.count == 64 }
        let started = Date()
        try client.send(query(999, "one-more.example"))
        let reply = try #require(try client.receive(wait: 2))
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(Reply(reply).id == 999)
        #expect(Reply(reply).rcode == DNSReply.servFail)
        #expect(resolver.asked.count == 64)
    }

    /// The bounds the plan names, as values: the tests above run most of them shortened.
    @Test func theBoundsAreThePlansValues() {
        #expect(DNSForwarder.messageLimit == 512)
        #expect(DNSForwarder.inFlightLimit == 64)
        #expect(DNSForwarder.tcpConnectionLimit == 16)
        #expect(DNSForwarder.ednsLimit == 1232)
        #expect(DNSForwarder.tcpReplyLimit == 65_535)
        #expect(DNSForwarder.defaultQueryBound == .seconds(4))
        #expect(DNSForwarder.defaultConnectionBound == .seconds(10))
        #expect(DNSForwarder.defaultLogInterval == .seconds(60))
    }

    /// A question answered before its bound leaves no timer behind to answer a later one.
    @Test func aFinishedQuestionsBoundTouchesNoOther() async throws {
        let resolver = ScriptedResolver { name, _ in
            name.hasPrefix("fast") ? [.now([a(name, [10, 0, 0, 1])])] : [.after(.milliseconds(500), [a(name, [10, 0, 0, 2])])]
        }
        let (forwarder, port) = try await started(resolver, queryBound: .milliseconds(600))
        defer { Task { await forwarder.stop() } }
        for round in 0..<5 {
            #expect(try udp(port: port, query(UInt16(2 * round), "fast\(round).example")) != nil)
            try await Task.sleep(for: .milliseconds(300))
            let slow = Reply(try #require(try udp(port: port, query(UInt16(2 * round + 1), "slow\(round).example"))))
            #expect(slow.rcode == DNSReply.noError, "round \(round)")
            #expect(slow.answers.count == 1, "round \(round)")
        }
    }

    /// Every question has its own bound, whenever it arrives: after the sweep has fired and found
    /// nothing left, and while it is set for a question already answered.
    @Test func everyQuestionIsBoundedWheneverItArrives() async throws {
        let resolver = ScriptedResolver { name, _ in name.hasPrefix("fast") ? [.now([a(name, [10, 0, 0, 1])])] : [] }
        let (forwarder, port) = try await started(resolver, queryBound: .milliseconds(400))
        defer { Task { await forwarder.stop() } }
        #expect(Reply(try #require(try udp(port: port, query(1, "never1.example")))).rcode == DNSReply.servFail)
        #expect(try udp(port: port, query(2, "fast.example")) != nil)
        try await Task.sleep(for: .milliseconds(100))
        let clients = try (0..<3).map { _ in try UDPClient(port: port) }
        defer { clients.forEach { $0.close() } }
        var asked: [Date] = []
        for (index, client) in clients.enumerated() {
            asked.append(Date())
            try client.send(query(UInt16(10 + index), "never\(index + 2).example"))
            try await Task.sleep(for: .milliseconds(150))
        }
        for (index, client) in clients.enumerated() {
            let reply = try #require(try client.receive(wait: 3), "question \(index) unanswered")
            let took = Date().timeIntervalSince(asked[index])
            #expect(Reply(reply).rcode == DNSReply.servFail)
            #expect(took >= 0.35 && took < 1.2, "question \(index) answered after \(took) s")
        }
        try await eventually { resolver.live == 0 }
    }

    /// A flood of questions answered at once holds nothing past its answers: no bound is left
    /// waiting per question for its 4 s.
    @Test func aFloodHoldsNothingPerQuestion() async throws {
        let forwarder = DNSForwarder(resolver: InstantResolver(), log: { _ in })
        let port = try await forwarder.start()
        defer { Task { await forwarder.stop() } }
        let clients = try (0..<8).map { _ in try UDPClient(port: port) }
        defer { clients.forEach { $0.close() } }
        for client in clients { _ = fcntl(client.fd, F_SETFL, fcntl(client.fd, F_GETFL) | O_NONBLOCK) }
        let bytes = query(1, "flood.example")
        var sink = [UInt8](repeating: 0, count: 2048)
        var answered = 0
        let before = footprint()
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            for client in clients {
                _ = withAddress("127.0.0.1", port) { sendto(client.fd, bytes, bytes.count, 0, $0, $1) }
                while recv(client.fd, &sink, sink.count, 0) > 0 { answered += 1 }
            }
        }
        let grown = (footprint() - before) / 1_000_000
        #expect(answered > 10_000, "the flood was \(answered) answers")
        #expect(grown < 30, "grew \(grown) MB over \(answered) answers")
    }

    /// Over UDP a reply of exactly the limit goes whole and one a byte longer truncated: 512 with no
    /// EDNS or an offer under it, the offer itself up to 1232 however much more is offered.
    @Test func aReplyAtTheLimitFitsAndOneByteMoreIsTruncated() async throws {
        let resolver = ScriptedResolver { name, _ in
            let size = Int(name.dropFirst(3).prefix(5)) ?? 0
            return [.now([RecordAnswer(outcome: .record, name: name, type: 16, ttl: 60,
                                       rdata: [UInt8](repeating: 0x61, count: size))])]
        }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        func name(_ size: Int) -> String { "pad" + String(format: "%05d", size) + ".example" }
        for (edns, limit) in [(nil, 512), (100, 512), (600, 600), (4096, 1232)] as [(UInt16?, Int)] {
            // Over TCP nothing is cut, so the reply's size for a record of 100 bytes gives the rest.
            let base = try #require(try tcp(port: port, [query(1, name(100), type: 16, edns: edns)]).first).count - 100
            let fitting = limit - base
            let fits = try #require(try udp(port: port, query(2, name(fitting), type: 16, edns: edns)))
            #expect(fits.count == limit, "edns \(String(describing: edns))")
            #expect(!Reply(fits).truncated, "edns \(String(describing: edns))")
            #expect(Reply(fits).answers.count == 1, "edns \(String(describing: edns))")
            let over = Reply(try #require(try udp(port: port, query(3, name(fitting + 1), type: 16, edns: edns))))
            #expect(over.truncated, "edns \(String(describing: edns))")
            #expect(over.answers.isEmpty, "edns \(String(describing: edns))")
        }
    }

    @Test func unansweredQueryServfailsAtBound() async throws {
        let resolver = ScriptedResolver { _, _ in [] }
        let (forwarder, port) = try await started(resolver, queryBound: .milliseconds(400))
        defer { Task { await forwarder.stop() } }
        let started = Date()
        let reply = try #require(try udp(port: port, query(7, "never.example"), wait: 3))
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.35 && took < 2, "answered after \(took) s")
        #expect(Reply(reply).rcode == DNSReply.servFail)
        #expect(Reply(reply).answers.isEmpty)
        #expect(resolver.cancelled == 1, "the query was not deallocated at the bound")
        #expect(resolver.live == 0)
    }

    @Test func tcpConnectionClosedAtBound() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver, connectionBound: .milliseconds(500))
        defer { Task { await forwarder.stop() } }
        let fd = try tcpOpen(port: port)
        defer { Darwin.close(fd) }
        let started = Date()
        #expect(readUntilClosed(fd, wait: 5))
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.4 && took < 3, "closed after \(took) s")
    }

    @Test func tcpConnectionCapRefusesSeventeenth() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver, connectionBound: .seconds(30))
        defer { Task { await forwarder.stop() } }
        var open: [Int32] = []
        defer { open.forEach { Darwin.close($0) } }
        for id in 0..<DNSForwarder.tcpConnectionLimit {
            let fd = try tcpOpen(port: port)
            open.append(fd)
            #expect(try tcpExchange(fd, query(UInt16(id), "x.example")) != nil, "connection \(id + 1) was not answered")
        }
        let seventeenth = try tcpOpen(port: port)
        open.append(seventeenth)
        #expect(try tcpExchange(seventeenth, query(99, "x.example")) == nil)
        #expect(resolver.asked.count == DNSForwarder.tcpConnectionLimit)
        // Closing one makes room for the next.
        Darwin.close(open.removeFirst())
        try await Task.sleep(for: .milliseconds(200))
        let next = try tcpOpen(port: port)
        open.append(next)
        #expect(try tcpExchange(next, query(100, "x.example")) != nil)
    }

    /// Every client gets its own reply, however many ask at once: a reply goes to the address its
    /// question came from and to no other.
    @Test func concurrentClientsEachGetTheirOwnReply() async throws {
        let resolver = ScriptedResolver { name, _ in [.after(.milliseconds(100), [a(name, [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let clients = try (0..<40).map { _ in try UDPClient(port: port) }
        defer { clients.forEach { $0.close() } }
        for (id, client) in clients.enumerated() { try client.send(query(UInt16(id), "c\(id).example")) }
        for (id, client) in clients.enumerated() {
            let reply = try client.receive(wait: 3)
            #expect(reply.map { Reply($0).id } == UInt16(id), "client \(id)")
        }
    }

    @Test func largeAnswerTruncatedOverUDPWholeOverTCP() async throws {
        let many = (1...40).map { a("big.example.", [10, 0, 0, UInt8($0)], more: $0 < 40) }
        let resolver = ScriptedResolver { _, _ in [.now(many)] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let plain = Reply(try #require(try udp(port: port, query(1, "big.example"))))
        #expect(plain.truncated)
        #expect(plain.rcode == DNSReply.noError)
        #expect(plain.answers.isEmpty)
        let edns = Reply(try #require(try udp(port: port, query(2, "big.example", edns: 4096))))
        #expect(!edns.truncated)
        #expect(edns.answers.count == 40)
        let small = Reply(try #require(try udp(port: port, query(3, "big.example", edns: 600))))
        #expect(small.truncated)
        let whole = try tcp(port: port, [query(4, "big.example")])
        #expect(whole.count == 1)
        #expect(!Reply(whole[0]).truncated)
        #expect(Reply(whole[0]).answers.count == 40)
    }

    @Test func malformedQueryReachesNoResolver() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        var two = query(1, "x.example")
        two[5] = 2
        #expect(Reply(try #require(try udp(port: port, two))).rcode == DNSReply.formErr)
        var status = query(2, "x.example")
        status[2] |= 2 << 3
        #expect(Reply(try #require(try udp(port: port, status))).rcode == DNSReply.notImp)
        var chaos = query(3, "x.example")
        chaos[chaos.count - 1] = 3
        #expect(Reply(try #require(try udp(port: port, chaos))).rcode == DNSReply.notImp)
        var pointer = query(4, "x.example")
        pointer[12] = 0xc0
        #expect(Reply(try #require(try udp(port: port, pointer))).rcode == DNSReply.formErr)
        var reply = query(5, "x.example")
        reply[2] |= 0x80
        #expect(try udp(port: port, reply, wait: 0.5) == nil)
        #expect(try udp(port: port, [1, 2, 3, 4, 5], wait: 0.5) == nil)
        // What a web page can send: its request line's first two bytes read as a length of 18245.
        #expect(try tcpClosedAfter(port: port, raw: Array("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)))
        #expect(resolver.asked.isEmpty)
    }

    // MARK: Review focus 4

    @Test func logCarriesCountsOnly() async throws {
        let lines = Lines()
        let resolver = ScriptedResolver { name, _ in
            name.hasPrefix("secret-missing") ? [.now([.init(outcome: .noSuchName)])]
                : [.now([a(name, [10, 0, 0, 9])])]
        }
        let forwarder = DNSForwarder(resolver: resolver, logInterval: .milliseconds(200), log: { lines.add($0) })
        let port = try await forwarder.start()
        defer { Task { await forwarder.stop() } }
        let names = ["secret-alpha.example", "secret-missing.internal", "secret-gamma.corp"]
        for (id, name) in names.enumerated() { _ = try udp(port: port, query(UInt16(id), name)) }
        _ = try udp(port: port, [9, 9, 9], wait: 0.2)
        try await eventually { lines.all.joined().contains("3 answered") }
        let pattern = /^dns: \d+ [a-z ]+(, \d+ [a-z ]+)*$/
        for line in lines.all {
            #expect(line.wholeMatch(of: pattern) != nil, "\(line)")
            for label in names.flatMap({ $0.split(separator: ".") }) {
                #expect(!line.contains(label), "\(line) names \(label)")
            }
            #expect(!line.contains("10.0.0.9"))
        }
        // One line per interval at most: nothing more while nothing happens.
        let count = lines.all.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(lines.all.count == count)
    }

    // MARK: Review focus 8

    @Test func noCache() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("same.example.", [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        _ = try udp(port: port, query(1, "same.example"))
        _ = try udp(port: port, query(2, "same.example"))
        #expect(resolver.asked.count == 2)
    }

    // MARK: Review focus 9

    @Test func cnameBatchThenTargetIsOneAnswer() async throws {
        let resolver = ScriptedResolver { _, _ in
            [.now([cname("www.example.", to: "example.")]),
             .after(.milliseconds(400), [a("example.", [10, 0, 0, 2])])]
        }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let started = Date()
        let reply = Reply(try #require(try udp(port: port, query(1, "www.example"))))
        #expect(Date().timeIntervalSince(started) >= 0.35, "answered on the CNAME's batch")
        #expect(reply.rcode == DNSReply.noError)
        #expect(reply.answers.map(\.type) == [5, 1])
        #expect(reply.answers.last?.rdata == [10, 0, 0, 2])
        #expect(resolver.cancelled == 1)
    }

    @Test func cnameChainInOneBatch() async throws {
        let resolver = ScriptedResolver { _, _ in
            [.now([cname("www.example.", to: "edge.example.", more: true),
                   cname("edge.example.", to: "e1.cdn.example.", more: true),
                   a("e1.cdn.example.", [10, 0, 0, 3])])]
        }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "www.example"))))
        #expect(reply.answers.map(\.type) == [5, 5, 1])
        #expect(reply.answers.first?.name == "www.example")
    }

    @Test func cnameThenBoundIsServfail() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([cname("www.example.", to: "example.")])] }
        let (forwarder, port) = try await started(resolver, queryBound: .milliseconds(400))
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "www.example"), wait: 3)))
        #expect(reply.rcode == DNSReply.servFail)
        #expect(reply.answers.isEmpty)
    }

    @Test func noSuchNameIsNXDOMAIN() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([.init(outcome: .noSuchName, name: "nx.example.", type: 1)])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "nx.example"))))
        #expect(reply.rcode == DNSReply.nxDomain)
        #expect(reply.answers.isEmpty)
    }

    @Test func noSuchRecordIsNODATA() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([.init(outcome: .noSuchRecord, name: "v4.example.", type: 28)])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "v4.example", type: 28))))
        #expect(reply.rcode == DNSReply.noError)
        #expect(reply.answers.isEmpty)
        #expect(!reply.truncated)
    }

    @Test func cnameThenNoSuchRecordKeepsCname() async throws {
        let resolver = ScriptedResolver { _, _ in
            [.now([cname("www.example.", to: "v4.example.", more: true),
                   .init(outcome: .noSuchRecord, name: "v4.example.", type: 28)])]
        }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "www.example", type: 28))))
        #expect(reply.rcode == DNSReply.noError)
        #expect(reply.answers.map(\.type) == [5])
    }

    @Test func otherErrorIsServfail() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([.init(outcome: .failed(-65569))])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let reply = Reply(try #require(try udp(port: port, query(1, "x.example"))))
        #expect(reply.rcode == DNSReply.servFail)
        #expect(resolver.cancelled == 1)
    }

    // MARK: The reply

    @Test func aReplyEchoesTheQuestionAndCarriesTheRecords() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([a("x.example.", [10, 0, 0, 1], ttl: 123)])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        let asked = query(0xbeef, "X.Example")
        let bytes = try #require(try udp(port: port, asked))
        let reply = Reply(bytes)
        #expect(reply.id == 0xbeef)
        #expect(bytes[2] & 0x80 != 0, "QR")
        #expect(bytes[2] & 0x01 != 0, "RD echoed")
        #expect(bytes[3] & 0x80 != 0, "RA")
        #expect(Array(bytes[12..<asked.count]) == Array(asked[12...]), "the question as asked")
        #expect(reply.answers.map(\.ttl) == [123])
        #expect(resolver.asked.first?.name == "X.Example.")
        #expect(resolver.asked.first?.type == 1)
    }

    @Test func aNameWithADotInALabelIsAskedEscaped() async throws {
        let resolver = ScriptedResolver { _, _ in [.now([.init(outcome: .noSuchName)])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        _ = try udp(port: port, query(1, labels: [Array("a.b".utf8), [0x20, 0xff], Array("example".utf8)]))
        #expect(resolver.asked.first?.name == "a\\.b.\\032\\255.example.")
        #expect(DNSRecord.labels(presentation: Array("a\\.b.\\032\\255.example.".utf8))
                == [Array("a.b".utf8), [0x20, 0xff], Array("example".utf8)])
    }

    /// Two starts at once are one: one port, one `up`, and nothing left listening after a stop.
    @Test func startingTwiceAtOnceIsOneStart() async throws {
        let seen = Lines()
        let forwarder = DNSForwarder(resolver: ScriptedResolver { _, _ in [] }, log: { _ in })
        await forwarder.observe { seen.add($0.map { "up \($0)" } ?? "down") }
        async let first = forwarder.start()
        async let second = forwarder.start()
        let (a, b) = try await (first, second)
        #expect(a == b)
        await forwarder.stop()
        #expect(seen.all == ["up \(a)", "down"])
        #expect(tcpConnect(host: "127.0.0.1", port: a) == ECONNREFUSED, "a listener outlived the stop")
    }

    /// A client that goes before its reply takes nothing down: the next client is answered.
    @Test func aClientThatVanishedTakesNothingDown() async throws {
        let seen = Lines()
        let resolver = ScriptedResolver { name, _ in [.after(.milliseconds(400), [a(name, [10, 0, 0, 1])])] }
        let (forwarder, port) = try await started(resolver)
        defer { Task { await forwarder.stop() } }
        await forwarder.observe { seen.add($0.map { "up \($0)" } ?? "down") }
        let gone = try UDPClient(port: port)
        try gone.send(query(1, "gone.example"))
        gone.close()
        try await Task.sleep(for: .milliseconds(700))
        #expect(try udp(port: port, query(2, "next.example")) != nil)
        #expect(seen.all.isEmpty)
        #expect(await forwarder.port == port)
    }

    /// A listener that fails or is taken away, or a UDP socket that fails, is the forwarder down,
    /// observed and logged, and a start after it is up again.
    @Test func aListenerOrSocketLostIsTheForwarderDown() async throws {
        let seen = Lines()
        let logged = Lines()
        let forwarder = DNSForwarder(resolver: ScriptedResolver { _, _ in [] }, log: { logged.add($0) })
        await forwarder.observe { seen.add($0 == nil ? "down" : "up") }
        _ = try await forwarder.start()
        await forwarder.tcp?.cancel()
        try await eventually { seen.all == ["up", "down"] }
        #expect(await forwarder.port == nil)
        let port = try await forwarder.start()
        #expect(port != 0)
        let generation = await forwarder.generation
        await forwarder.drain(-1, generation: generation)
        try await eventually { seen.all == ["up", "down", "up", "down"] }
        #expect(await forwarder.port == nil)
        #expect(logged.all.filter { $0.hasPrefix("dns: forwarder lost") }.count == 2)
    }

    @Test func stopAndStartAreObserved() async throws {
        let seen = Lines()
        let forwarder = DNSForwarder(resolver: ScriptedResolver { _, _ in [] }, log: { _ in })
        await forwarder.observe { seen.add($0.map { "up \($0)" } ?? "down") }
        let first = try await forwarder.start()
        await forwarder.stop()
        let second = try await forwarder.start()
        await forwarder.stop()
        await forwarder.stop()
        #expect(seen.all == ["up \(first)", "down", "up \(second)", "down"])
        #expect(try udp(port: second, query(1, "x.example"), wait: 0.3) == nil)
    }
}

// MARK: The scripted resolver

/// Answers every question with one address at once, keeping nothing.
final class InstantResolver: RecordResolver, @unchecked Sendable {
    final class Handle: ResolverQuery, @unchecked Sendable { func cancel() {} }
    func query(name: String, type: UInt16, queue: DispatchSerialQueue,
               answer: @escaping @Sendable (RecordAnswer) -> Void) -> any ResolverQuery {
        let item = RecordAnswer(outcome: .record, name: name, type: 1, ttl: 5, rdata: [10, 0, 0, 1])
        queue.async { answer(item) }
        return Handle()
    }
}

/// The process's physical footprint in bytes.
func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Answers each query with batches of callbacks, now or after a delay, on the forwarder's queue,
/// and counts what it was asked and what it cancelled.
final class ScriptedResolver: RecordResolver, @unchecked Sendable {
    enum Step {
        case now([RecordAnswer])
        case after(Duration, [RecordAnswer])
    }

    private let script: @Sendable (String, UInt16) -> [Step]
    private let lock = NSLock()
    private var _asked: [(name: String, type: UInt16)] = []
    private var _cancelled = 0
    private var _live = 0

    init(_ script: @escaping @Sendable (String, UInt16) -> [Step]) { self.script = script }

    var asked: [(name: String, type: UInt16)] { lock.withLock { _asked } }
    var cancelled: Int { lock.withLock { _cancelled } }
    var live: Int { lock.withLock { _live } }

    func query(name: String, type: UInt16, queue: DispatchSerialQueue,
               answer: @escaping @Sendable (RecordAnswer) -> Void) -> any ResolverQuery {
        dispatchPrecondition(condition: .onQueue(queue))
        lock.withLock { _asked.append((name, type)); _live += 1 }
        let handle = Handle(self)
        var delay = Duration.zero
        for step in script(name, type) {
            let batch: [RecordAnswer]
            switch step {
            case .now(let answers): batch = answers
            case .after(let wait, let answers): delay += wait; batch = answers
            }
            queue.asyncAfter(deadline: .now() + delay.timeInterval) {
                for item in batch where !handle.isCancelled { answer(item) }
            }
        }
        return handle
    }

    final class Handle: ResolverQuery, @unchecked Sendable {
        private let resolver: ScriptedResolver
        private(set) var isCancelled = false
        init(_ resolver: ScriptedResolver) { self.resolver = resolver }
        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            resolver.lock.withLock { resolver._cancelled += 1; resolver._live -= 1 }
        }
    }
}

func a(_ name: String, _ address: [UInt8], ttl: UInt32 = 60, more: Bool = false) -> RecordAnswer {
    RecordAnswer(outcome: .record, moreComing: more, name: name, type: 1, ttl: ttl, rdata: address)
}

func cname(_ name: String, to target: String, more: Bool = false) -> RecordAnswer {
    let labels = target.split(separator: ".").map { Array($0.utf8) }
    return RecordAnswer(outcome: .record, moreComing: more, name: name, type: 5, ttl: 300,
                        rdata: labels.flatMap { [UInt8($0.count)] + $0 } + [0])
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

func started(_ resolver: ScriptedResolver, queryBound: Duration = DNSForwarder.defaultQueryBound,
             connectionBound: Duration = DNSForwarder.defaultConnectionBound) async throws -> (DNSForwarder, UInt16) {
    let forwarder = DNSForwarder(resolver: resolver, queryBound: queryBound, connectionBound: connectionBound, log: { _ in })
    return (forwarder, try await forwarder.start())
}

func eventually(_ condition: () -> Bool, within: Duration = .seconds(5)) async throws {
    let end = ContinuousClock.now + within
    while !condition() {
        guard ContinuousClock.now < end else { Issue.record("never became true"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: Messages

func query(_ id: UInt16, _ name: String, type: UInt16 = 1, edns: UInt16? = nil, optPadding: Int = 0) -> [UInt8] {
    query(id, labels: name.split(separator: ".").map { Array($0.utf8) }, type: type, edns: edns, optPadding: optPadding)
}

func query(_ id: UInt16, labels: [[UInt8]], type: UInt16 = 1, edns: UInt16? = nil, optPadding: Int = 0) -> [UInt8] {
    var out: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0, 0, 1, 0, 0, 0, 0, 0, edns == nil ? 0 : 1]
    out += labels.flatMap { [UInt8($0.count)] + $0 } + [0]
    out += [UInt8(type >> 8), UInt8(type & 0xff), 0, 1]
    if let edns {
        // An OPT record, its data an option of padding (code 12) when asked for.
        let data: [UInt8] = optPadding >= 4 ? [0, 12, UInt8((optPadding - 4) >> 8), UInt8((optPadding - 4) & 0xff)]
            + [UInt8](repeating: 0, count: optPadding - 4) : []
        out += [0, 0, 41, UInt8(edns >> 8), UInt8(edns & 0xff), 0, 0, 0, 0, UInt8(data.count >> 8), UInt8(data.count & 0xff)] + data
    }
    return out
}

struct Reply {
    struct Record { let name: String; let type: UInt16; let ttl: UInt32; let rdata: [UInt8] }
    let id: UInt16
    let rcode: UInt8
    let truncated: Bool
    let answers: [Record]

    init(_ bytes: [UInt8]) {
        id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        rcode = bytes[3] & 0x0f
        truncated = bytes[2] & 0x02 != 0
        let qd = Int(bytes[5]), an = Int(bytes[6]) << 8 | Int(bytes[7])
        var at = 12
        func name() -> String {
            var labels: [String] = []
            while bytes[at] != 0 {
                let length = Int(bytes[at])
                labels.append(String(decoding: bytes[(at + 1)...(at + length)], as: UTF8.self))
                at += length + 1
            }
            at += 1
            return labels.joined(separator: ".")
        }
        for _ in 0..<qd { _ = name(); at += 4 }
        var records: [Record] = []
        for _ in 0..<an {
            let owner = name()
            let type = UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            let ttl = UInt32(bytes[at + 4]) << 24 | UInt32(bytes[at + 5]) << 16 | UInt32(bytes[at + 6]) << 8 | UInt32(bytes[at + 7])
            let length = Int(bytes[at + 8]) << 8 | Int(bytes[at + 9])
            at += 10
            records.append(Record(name: owner, type: type, ttl: ttl, rdata: Array(bytes[at..<(at + length)])))
            at += length
        }
        answers = records
    }
}

// MARK: Sockets

struct SocketError: Error { let errno: Int32 }

func address(_ host: String, _ port: UInt16) -> sockaddr_in {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr.s_addr = inet_addr(host)
    return sin
}

func withAddress<T>(_ host: String, _ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var sin = address(host, port)
    return withUnsafePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

func setTimeout(_ fd: Int32, _ seconds: Double) {
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

final class UDPClient {
    let fd: Int32
    let host: String
    let port: UInt16

    init(port: UInt16, host: String = "127.0.0.1") throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError(errno: errno) }
        self.host = host
        self.port = port
    }

    func send(_ bytes: [UInt8]) throws {
        let sent = withAddress(host, port) { sendto(fd, bytes, bytes.count, 0, $0, $1) }
        guard sent == bytes.count else { throw SocketError(errno: errno) }
    }

    /// The next datagram, or nil when none came within `wait` seconds.
    func receive(wait: Double) throws -> [UInt8]? {
        setTimeout(fd, wait)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = recv(fd, &buffer, buffer.count, 0)
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw SocketError(errno: errno)
        }
        return Array(buffer[0..<count])
    }

    func close() { Darwin.close(fd) }
}

/// One datagram to the forwarder and the reply, or nil when none came within `wait` seconds.
func udp(port: UInt16, _ bytes: [UInt8], host: String = "127.0.0.1", wait: Double = 3) throws -> [UInt8]? {
    let client = try UDPClient(port: port, host: host)
    defer { client.close() }
    try client.send(bytes)
    return try client.receive(wait: wait)
}

func tcpOpen(port: UInt16, host: String = "127.0.0.1") throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError(errno: errno) }
    setTimeout(fd, 3)
    guard withAddress(host, port, { Darwin.connect(fd, $0, $1) }) == 0 else {
        let error = errno
        Darwin.close(fd)
        throw SocketError(errno: error)
    }
    return fd
}

/// The errno a blocking connect ended with (0 for connected).
func tcpConnect(host: String, port: UInt16) -> Int32 {
    do {
        Darwin.close(try tcpOpen(port: port, host: host))
        return 0
    } catch let error as SocketError {
        return error.errno
    } catch {
        return -1
    }
}

/// One length-prefixed query on an open connection and its reply, or nil when the connection
/// closed or said nothing within `wait` seconds.
func tcpExchange(_ fd: Int32, _ bytes: [UInt8], wait: Double = 3) throws -> [UInt8]? {
    let framed = [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
    guard write(fd, framed, framed.count) == framed.count else { return nil }
    setTimeout(fd, wait)
    guard let prefix = readExactly(fd, 2) else { return nil }
    return readExactly(fd, Int(prefix[0]) << 8 | Int(prefix[1]))
}

func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: max(count, 1))
    while out.count < count {
        let n = read(fd, &buffer, count - out.count)
        guard n > 0 else { return nil }
        out += buffer[0..<n]
    }
    return out
}

/// Queries on one connection, their replies in order.
func tcp(port: UInt16, _ queries: [[UInt8]]) throws -> [[UInt8]] {
    let fd = try tcpOpen(port: port)
    defer { Darwin.close(fd) }
    return try queries.compactMap { try tcpExchange(fd, $0) }
}

/// Whether the connection is closed from the other side within `wait` seconds.
func readUntilClosed(_ fd: Int32, wait: Double) -> Bool {
    setTimeout(fd, wait)
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n == 0 { return true }
        if n < 0 { return errno == ECONNRESET }
    }
}

/// Whether a connection is closed with nothing said after `raw`, or after a length prefix of
/// `lengthPrefix` followed by that many bytes.
func tcpClosedAfter(port: UInt16, lengthPrefix: Int? = nil, raw: [UInt8] = []) throws -> Bool {
    let fd = try tcpOpen(port: port)
    defer { Darwin.close(fd) }
    var bytes = raw
    if let lengthPrefix {
        bytes = [UInt8(lengthPrefix >> 8), UInt8(lengthPrefix & 0xff)] + [UInt8](repeating: 0, count: lengthPrefix)
    }
    _ = write(fd, bytes, bytes.count)
    return readUntilClosed(fd, wait: 3)
}

func nonLoopbackIPv4Addresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var found: [String] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            found.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
    return found
}
