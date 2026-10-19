import TopoProxy
import TopoTools
import XCTest

@testable import Topo

/// What each launch of the resident is told of the proxy and the tool service (#369): asked for
/// at every launch, so a launch after a listener went away is told the port listening now.
@MainActor
final class LaunchPortsTests: XCTestCase {
    func testEachLaunchIsToldThePortsListeningNowAndAChangeIsSaid() async throws {
        let proxy = try APIProxy(log: { _ in })
        let tools = try ToolService(tools: [])
        let ports = LaunchPorts(proxy: proxy, tools: tools)
        let first = try await ports.ports()
        XCTAssertFalse(ports.made(first), "the first launch changed nothing")
        let again = try await ports.ports()
        XCTAssertEqual(again.proxy, first.proxy)
        XCTAssertEqual(again.tools, first.tools)
        XCTAssertFalse(ports.made(again), "a launch told the same ports said they changed")

        // Both listeners gone, as iOS takes them from a suspended app.
        await proxy.stop()
        await tools.stop()
        let probes = await (LoopbackProbe.answers(port: first.proxy), LoopbackProbe.answers(port: first.tools))
        XCTAssertFalse(probes.0 || probes.1, "control: the first ports still answer")
        let next = try await ports.ports()
        let answers = await (LoopbackProbe.answers(port: next.proxy), LoopbackProbe.answers(port: next.tools))
        XCTAssertTrue(answers.0 && answers.1, "the next launch was told a port nothing listens on")
        XCTAssertTrue(ports.made(next) || (next.proxy == first.proxy && next.tools == first.tools),
                      "a launch told new ports did not say so")
        await proxy.stop()
        await tools.stop()
    }
}
