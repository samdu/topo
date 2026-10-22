import Darwin
import TopoProxy
import TopoTools
import TopoUserland
import XCTest

@testable import Topo

/// What each launch of the resident is told of the proxy and the tool service (#369), through
/// `ClaudeLauncher` as the session launches it: every launch starts both listeners anew and is
/// told the ports they have now.
@MainActor
final class LaunchPortsTests: XCTestCase {
    func testEachLaunchIsToldListenersStartedForItAndSaysWhich() async throws {
        let proxy = try APIProxy(log: { _ in })
        let tools = try ToolService(tools: [])
        let ports = LaunchPorts(proxy: proxy, tools: tools)
        let said = Said()
        let made = GuestResident.launchEnvironment(ports: ports, note: { said.add($0) }) { port in
            ["ANTHROPIC_BASE_URL": APIProxy.baseURL(port: port)]
        }
        let launcher = ClaudeLauncher(environment: made)

        let first = try await launcher.launchEnvironment()
        let firstProxyPort = await proxy.port
        let firstProxy = try XCTUnwrap(firstProxyPort)
        let firstToolsPort = await tools.port
        let firstTools = try XCTUnwrap(firstToolsPort)
        XCTAssertEqual(first["ANTHROPIC_BASE_URL"], APIProxy.baseURL(port: firstProxy))
        XCTAssertEqual(first[ToolService.urlVariable], "http://127.0.0.1:\(firstTools)")
        XCTAssertEqual(first[ToolService.tokenVariable], tools.token)
        XCTAssertEqual(said.all, ["guest: the launch is told the proxy at \(firstProxy) and the tools at \(firstTools)"])

        // The old ports held by others, as a process that took what iOS freed would hold them:
        // the next launch is told neither.
        let squatters = [try Self.squat(firstProxy), try Self.squat(firstTools)].compactMap { $0 }
        defer { squatters.forEach { close($0) } }
        let next = try await launcher.launchEnvironment()
        let nextProxyPort = await proxy.port
        let nextProxy = try XCTUnwrap(nextProxyPort)
        let nextToolsPort = await tools.port
        let nextTools = try XCTUnwrap(nextToolsPort)
        XCTAssertNotEqual(nextProxy, firstProxy)
        XCTAssertNotEqual(nextTools, firstTools)
        XCTAssertEqual(next["ANTHROPIC_BASE_URL"], APIProxy.baseURL(port: nextProxy))
        XCTAssertEqual(next[ToolService.urlVariable], "http://127.0.0.1:\(nextTools)")
        XCTAssertEqual(said.all.last, "guest: the launch is told the proxy at \(nextProxy) and the tools at \(nextTools)")
        await proxy.stop()
        await tools.stop()
    }

    /// A socket listening on `127.0.0.1` at `port` once the listener there has let it go; nil when
    /// it could not be bound in five seconds.
    private static func squat(_ port: UInt16) throws -> Int32? {
        for _ in 0..<500 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if bound == 0, listen(fd, 1) == 0 { return fd }
            close(fd)
            usleep(10_000)
        }
        XCTFail("port \(port) was never let go")
        return nil
    }
}

private final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
