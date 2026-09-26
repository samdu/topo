import Foundation
import Network
import Testing
import TopoProxy
@testable import TopoTools

@Suite struct ToolServiceTests {
    @Test func aCallRunsItsToolAndAnswersWithItsStatus() async throws {
        let tool = ScriptedTool()
        let (service, port, logs) = try await startedService([tool])
        defer { Task { await service.stop() } }
        let token = await service.token
        let (head, body) = call(port: port, token: token, ["echo", "a b", "", "ü$'\"\n"])
        let answer = try await exchange(port: port, head, body: body)
        #expect(answer.status == 200)
        #expect(answer.body == "exit: 0\na b||ü$'\"\n\n")
        #expect(tool.calls == [["a b", "", "ü$'\"\n"]])
        for _ in 0..<100 where logs.lines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(logs.lines.first?.hasPrefix("echo exit 0 in ") == true)
    }

    /// Review focus 1: without this service's token nothing runs.
    @Test func aCallWithoutTheTokenIsRefusedAndRunsNothing() async throws {
        let tool = ScriptedTool()
        let (service, port, _) = try await startedService([tool])
        defer { Task { await service.stop() } }
        let token = await service.token
        // No token line at all, an empty one, and the token in a header, where `wget` would have
        // to be given it as an argument: none of them is this service's token.
        for body in [Data(), Data("\n".utf8), ToolRequest.body(token: "", ["echo", "x"])] {
            let none = "POST /run HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(body.count)\r\n\r\n"
            #expect(try await exchange(port: port, none, body: body).status == 401)
        }
        let header = call(port: port, token: "", ["echo", "x"], extra: ["Authorization: Bearer \(token)"])
        #expect(try await exchange(port: port, header.0, body: header.1).status == 401)
        let wrong = call(port: port, token: String(token.reversed()), ["echo", "x"])
        #expect(try await exchange(port: port, wrong.0, body: wrong.1).status == 401)
        let prefix = call(port: port, token: String(token.dropLast()), ["echo", "x"])
        #expect(try await exchange(port: port, prefix.0, body: prefix.1).status == 401)
        let longer = call(port: port, token: token + "0", ["echo", "x"])
        #expect(try await exchange(port: port, longer.0, body: longer.1).status == 401)
        #expect(tool.calls.isEmpty)
    }

    /// Review focus 1: a browser's request is refused even carrying the token, and so is one
    /// addressed to any host but this one, and a preflight.
    @Test func aBrowsersRequestAForeignHostAndAPreflightAreRefused() async throws {
        let tool = ScriptedTool()
        let (service, port, _) = try await startedService([tool])
        defer { Task { await service.stop() } }
        let token = await service.token
        for (extra, host, method) in [
            (["Origin: https://example.com"], nil, "POST"),
            (["Origin: null"], nil, "POST"),
            (["Sec-Fetch-Mode: cors"], nil, "POST"),
            ([], "attacker.example:\(port)", "POST"),
            ([], "localhost:\(port)", "POST"),
            ([], "127.0.0.1:1", "POST"),
            (["Origin: https://example.com", "Access-Control-Request-Method: POST"], nil, "OPTIONS"),
            ([], nil, "OPTIONS"),
            ([], nil, "GET"),
        ] as [([String], String?, String)] {
            let (head, body) = call(port: port, token: token, ["echo", "x"], extra: extra, host: host, method: method)
            let status = try await exchange(port: port, head, body: body).status
            #expect(status != nil && status != 200, "\(method) \(extra) \(host ?? "") was answered \(String(describing: status))")
        }
        let other = call(port: port, token: token, ["echo", "x"], path: "/v1/messages")
        #expect(try await exchange(port: port, other.0, body: other.1).status == 404)
        let query = call(port: port, token: token, ["echo", "x"], path: "/run?x=1")
        #expect(try await exchange(port: port, query.0, body: query.1).status == 404)
        #expect(tool.calls.isEmpty)
    }

    /// Review focus 3: no log line carries the token, an argument or what the tool said.
    @Test func noLogLineCarriesTheTokenAnArgumentOrTheOutput() async throws {
        let secret = "argument-\(UUID().uuidString)"
        let said = "output-\(UUID().uuidString)"
        let tool = ScriptedTool(answer: { _ in .ok(said) })
        let (service, port, logs) = try await startedService([tool])
        defer { Task { await service.stop() } }
        let token = await service.token
        let good = call(port: port, token: token, ["echo", secret])
        _ = try await exchange(port: port, good.0, body: good.1)
        let bad = call(port: port, token: "wrong", ["echo", secret])
        _ = try await exchange(port: port, bad.0, body: bad.1)
        let unknown = call(port: port, token: token, [secret])
        _ = try await exchange(port: port, unknown.0, body: unknown.1)
        for _ in 0..<200 where logs.lines.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(logs.lines.count == 3)
        for line in logs.lines {
            for value in [token, secret, said] {
                #expect(!line.contains(value), "logged \(value): \(line)")
            }
        }
    }

    /// Review focus 6: a tool that never answers is answered for at the bound.
    @Test func aToolThatNeverAnswersIsAnsweredAtTheBound() async throws {
        let stuck = ScriptedTool(name: "stuck") { _ in
            // A prompt nobody answers for twenty seconds, which cancellation does not end.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { continuation.resume() }
            }
            return .ok("never")
        }
        let (service, port, _) = try await startedService([stuck], bound: .milliseconds(300))
        defer { Task { await service.stop() } }
        let token = await service.token
        let started = ContinuousClock.now
        let (head, body) = call(port: port, token: token, ["stuck"])
        let answer = try await exchange(port: port, head, body: body)
        #expect(answer.status == 200)
        #expect(answer.body.hasPrefix("exit: \(ToolReply.timedOut)\n"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Codex on #189: the bound runs from the connection's accept, so a client that sends a head
    /// promising a body and then one byte of it is answered or closed at the bound, not held.
    @Test func aClientThatNeverFinishesItsBodyIsLetGoAtTheBound() async throws {
        let tool = ScriptedTool()
        let (service, port, _) = try await startedService([tool], bound: .milliseconds(300))
        defer { Task { await service.stop() } }
        let token = await service.token
        let (head, body) = call(port: port, token: token, ["echo", "x"])
        let started = ContinuousClock.now
        let answer = try await exchange(port: port, head, body: body.prefix(1))
        #expect(ContinuousClock.now - started < .seconds(3), "held for \(ContinuousClock.now - started)")
        #expect(answer.status == 408)
        #expect(tool.calls.isEmpty)
    }

    @Test func helpListsEveryToolAndAnUnknownOneIsAUsageError() async throws {
        let (service, port, _) = try await startedService([ScriptedTool(name: "echo"), ScriptedTool(name: "look")])
        defer { Task { await service.stop() } }
        let token = await service.token
        for arguments in [[], ["help"]] {
            let (head, body) = call(port: port, token: token, arguments)
            let answer = try await exchange(port: port, head, body: body)
            #expect(answer.body.hasPrefix("exit: 0\n"))
            #expect(answer.body.contains("  echo  a scripted tool"))
            #expect(answer.body.contains("  look  a scripted tool"))
        }
        let (head, body) = call(port: port, token: token, ["help", "look"])
        #expect(try await exchange(port: port, head, body: body).body.contains("topo scripted <anything>"))
        let unknown = call(port: port, token: token, ["nope"])
        let answer = try await exchange(port: port, unknown.0, body: unknown.1)
        #expect(answer.body.hasPrefix("exit: 2\ntopo: no tool called nope"))
    }

    @Test func aBodyThatIsNotACallIsRefused() async throws {
        let tool = ScriptedTool()
        let (service, port, _) = try await startedService([tool])
        defer { Task { await service.stop() } }
        let token = await service.token
        for arguments in ["ZWNobw==", "echo\n", "/w==\n"] {
            let body = Data((token + "\n" + arguments).utf8)
            let head = "POST /run HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(body.count)\r\n\r\n"
            #expect(try await exchange(port: port, head, body: body).status == 400)
        }
        let large = Data(repeating: 0x61, count: ToolService.bodyLimit + 1)
        let head = "POST /run HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(large.count)\r\n\r\n"
        #expect(try await exchange(port: port, head).status == 413)
        #expect(tool.calls.isEmpty)
    }

    @Test func theEnvironmentNamesThePortAndTheToken() {
        #expect(ToolService.environment(port: 4242, token: "t") == ["TOPO_TOOLS_URL": "http://127.0.0.1:4242", "TOPO_TOOLS_TOKEN": "t"])
        let a = ToolService.newToken(), b = ToolService.newToken()
        #expect(a.count == 64 && a != b)
    }
}

@Suite struct ToolRequestTests {
    /// Review focus 13.
    @Test func argumentsRoundTripWhateverTheyHoldIncludingEmptyOnes() throws {
        for arguments in [[], [""], ["", ""], ["a b", "c\nd", "ü", "$HOME", "'\"", ""], ["look", "set", "transcript.replyTrailingInset", "24"]] {
            let split = try #require(ToolRequest.split(ToolRequest.body(token: "t0k", arguments)))
            #expect(split.token == "t0k")
            #expect(try ToolRequest.arguments(from: split.arguments) == arguments)
        }
        #expect(ToolRequest.split(Data("no newline".utf8)) == nil)
        #expect(throws: ToolRequest.Refusal.unterminated) { try ToolRequest.arguments(from: Data("YQ==".utf8)) }
        #expect(throws: ToolRequest.Refusal.notBase64) { try ToolRequest.arguments(from: Data("a b\n".utf8)) }
        #expect(throws: ToolRequest.Refusal.notUTF8) { try ToolRequest.arguments(from: Data("/w==\n".utf8)) }
    }
}

@Suite struct ToolLoopbackTests {
    /// Review focus 2: the listener is bound to 127.0.0.1 and nothing else.
    @Test func theListenerIsBoundToLoopbackAlone() async throws {
        let (service, port, _) = try await startedService([])
        defer { Task { await service.stop() } }
        let addresses = nonLoopbackIPv4Addresses()
        try #require(!addresses.isEmpty, "this machine has no non-loopback IPv4 address to try")
        #expect(connect(to: "127.0.0.1", port: port) == 0)
        for address in addresses {
            #expect(connect(to: address, port: port) == ECONNREFUSED, "\(address):\(port) accepted a connection")
        }
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
                found.append(String(cString: host))
            }
        }
        return found
    }

    /// A blocking connect, and the errno it ended with (0 for connected).
    func connect(to address: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        // A bound on the attempt, so an address that drops the SYN fails the test in seconds.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &sin.sin_addr)
        let result = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? 0 : errno
    }
}
