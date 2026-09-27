import TopoAuth
import TopoProxy
import TopoTools
import TopoUserland
import XCTest

@testable import Topo

/// The resident's environment as `GuestResident.start` builds its launcher: the egress proxy's
/// variables beside the API proxy's and the tool service's, read at every launch.
final class GuestResidentEgressTests: XCTestCase {
    /// A fallback whose token changes from one launch to the next, as a refresh would change it.
    private final class Counting: TokenProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func accessToken() async throws -> String {
            lock.withLock { count += 1; return "sk-ant-oat01-launch-\(count)" }
        }
    }

    func testEnvironmentCarriesCurrentEgressPort() async throws {
        let credential = GuestCredential(store: InMemoryTokenStore(), fallback: Counting())
        let tools = ToolService.environment(port: 4000, token: "tools-token")
        let launcher = GuestResident.launcher(apiPort: 4100, egressPort: 4200, credential: credential, tools: tools)
        // Two launches of the one launcher: a process started and then its replacement.
        let first = try await launcher.launchEnvironment()
        let second = try await launcher.launchEnvironment()
        for (launch, environment) in [(1, first), (2, second)] {
            XCTAssertEqual(environment["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-launch-\(launch)")
            XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:4100")
            for (key, value) in EgressProxy.guestEnvironment(port: 4200) {
                XCTAssertEqual(environment[key], value, "launch \(launch): \(key)")
            }
            XCTAssertEqual(environment["http_proxy"], "http://127.0.0.1:4200")
            XCTAssertEqual(environment["no_proxy"], "127.0.0.1,localhost")
            XCTAssertNil(environment["https_proxy"])
            XCTAssertNil(environment["HTTPS_PROXY"])
            for (key, value) in tools { XCTAssertEqual(environment[key], value, "launch \(launch): \(key)") }
            XCTAssertEqual(environment["HOME"], ClaudeLauncher.home)
            XCTAssertEqual(environment["IS_SANDBOX"], "1")
        }
    }
}
