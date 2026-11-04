import XCTest
import TopoUserland

/// `nanosleep` and `clock_nanosleep` in the booted guest refuse a timespec Linux refuses
/// (`patches/ish/0018-nanosleep-einval.patch`): a negative second, a negative nanosecond and a
/// nanosecond of 1e9 are EINVAL rather than no wait or a second's, and a sleep inside the yield's
/// 50 µs and one past it still return 0.
final class GuestSleepTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testASleepLinuxRefusesIsEINVAL() async throws {
        // The program is a static aarch64 build of the C beside it (`Tests/Programs/nanosleep.c`),
        // mounted from a copy the guest may execute.
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/nanosleep")
        let dir = fm.temporaryDirectory.appendingPathComponent("nanosleep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("nanosleep")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/nanosleep-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/nanosleep")
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "nanosleep -22 -22 -22 0 0 clock_nanosleep -22 -22 -22 0\n")
    }
}
