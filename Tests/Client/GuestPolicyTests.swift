import XCTest

@testable import Topo

/// Claude Code's managed policy in the guest: a debug build holds every claude to Haiku and fails
/// its boot rather than start one unpinned; a release build takes away one a debug build left, and
/// says so when it cannot.
final class GuestPolicyTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        var asked: [String?] = []
        var said: [String] = []
    }

    private struct Refused: Error {}

    /// The suites run a debug build, so the build's own settings are the pin, and the pin names
    /// Haiku alone with every other family refused.
    func testADebugBuildsPolicyIsHaikuAlone() throws {
        XCTAssertEqual(GuestPolicy.forBuild, GuestPolicy.haikuOnly)
        let policy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(GuestPolicy.haikuOnly.utf8)) as? [String: Any])
        XCTAssertEqual(policy["availableModels"] as? [String], ["haiku"])
        XCTAssertEqual(policy["enforceAvailableModels"] as? Bool, true)
        XCTAssertEqual(Set(policy["deniedModels"] as? [String] ?? []), ["opus", "sonnet", "fable"])
    }

    func testThePinIsWrittenAndAPinThatCannotBeIsTheBootsFailure() async {
        let writes = Writes()
        do {
            try await GuestPolicy.apply(GuestPolicy.haikuOnly, write: { writes.asked.append($0) }, log: { writes.said.append($0) })
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(writes.asked, [GuestPolicy.haikuOnly])
        do {
            try await GuestPolicy.apply(GuestPolicy.haikuOnly, write: { _ in throw Refused() }, log: { writes.said.append($0) })
            XCTFail("a pin that could not be written let the boot go on")
        } catch {
            XCTAssertTrue(error is Refused, "\(error)")
        }
        XCTAssertEqual(writes.said, [])
    }

    /// A release build asks for the file's removal every boot, a debug build's left one included,
    /// and a removal that fails is said and is not the boot's failure.
    func testAReleaseBuildRemovesThePolicyAndSaysWhenItCannot() async throws {
        let writes = Writes()
        try await GuestPolicy.apply(nil, write: { writes.asked.append($0) }, log: { writes.said.append($0) })
        XCTAssertEqual(writes.asked, [nil])
        XCTAssertEqual(writes.said, [])
        try await GuestPolicy.apply(nil, write: { _ in throw Refused() }, log: { writes.said.append($0) })
        XCTAssertEqual(writes.said.count, 1)
        XCTAssertTrue(writes.said[0].hasPrefix("guest policy: the managed settings a debug build left could not be removed"), writes.said[0])
    }
}
