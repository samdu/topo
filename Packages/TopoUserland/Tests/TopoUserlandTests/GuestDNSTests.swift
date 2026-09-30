import XCTest
import TopoUserland

/// The guest's DNS stub (`patches/ish/0006-dns-sentinel.patch`): `127.0.0.53` port 53 carried to
/// `127.0.0.1` at the port the app set, and back.
final class GuestDNSTests: XCTestCase {
    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDown() async throws {
        Guest.shared.setDNSPort(nil)
    }

    func testMuslResolvesThroughTheStub() async throws {
        let stub = try StubDNS(address: [10, 1, 2, 3])
        defer { stub.stop() }
        Guest.shared.setDNSPort(stub.port)
        try await Guest.shared.writeResolver(servers: [Guest.dnsStub])
        let exit = try await Guest.shared.run("/usr/bin/getent", ["hosts", "probe.example"])
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.output.split(separator: " ").first, "10.1.2.3")
        XCTAssertGreaterThan(stub.queries, 0)
    }
}
