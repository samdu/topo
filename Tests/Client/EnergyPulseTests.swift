import XCTest

@testable import Topo

@MainActor
final class EnergyPulseTests: XCTestCase {
    /// The emulator names a guest process's host thread `<command>-<pid>`, and the command is
    /// the person's; the thread is counted as the guest's.
    func testAGuestThreadIsKnownByItsPidSuffix() {
        XCTAssertTrue(EnergyPulse.isGuestThread("krista-med-1234"))
        XCTAssertTrue(EnergyPulse.isGuestThread("sh-7"))
        XCTAssertFalse(EnergyPulse.isGuestThread("com.apple.NSURLSession-work"))
        XCTAssertFalse(EnergyPulse.isGuestThread("JSCWarmUp"))
        XCTAssertFalse(EnergyPulse.isGuestThread("-12"))
        XCTAssertFalse(EnergyPulse.isGuestThread("claude-"))
        XCTAssertFalse(EnergyPulse.isGuestThread(""))
    }

    /// The newest payloads of a kind stay, by the seconds in the name, and the other kind's
    /// files are not what makes room.
    func testPruningKeepsTheNewestOfEachKind() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("energy-pulse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = (1...16).map { "metrics-\(1_000_000 + $0 * 86_400).json" }
            + ["diagnostics-1000100.json", "diagnostics-2500000.json", "metrics-900000.json"]
        for name in names {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }

        EnergyPulse.prune(dir, prefix: "metrics", keep: 14)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left.filter { $0.hasPrefix("metrics-") }.count, 14)
        XCTAssertFalse(left.contains("metrics-900000.json"))
        XCTAssertFalse(left.contains("metrics-1086400.json"))
        XCTAssertFalse(left.contains("metrics-1172800.json"))
        XCTAssertTrue(left.contains("metrics-2382400.json"))
        XCTAssertTrue(left.contains("diagnostics-1000100.json"))
        XCTAssertTrue(left.contains("diagnostics-2500000.json"))
    }
}
