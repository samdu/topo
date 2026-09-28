import XCTest
import TopoUserland

/// SQABS and SQNEG (vector) in the booted guest (`patches/ish/0005-sqabs-sqneg-vector.patch`), as
/// the architecture has them: every arrangement, saturating each type's minimum to its maximum and
/// zeroing the upper half for the 64-bit forms, and the unallocated 1D arrangement still an illegal
/// instruction. ugrep's line numbering, which Claude Code's Bash tool runs as `grep`, reaches SQABS.
final class GuestSimdTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testSQABSAndSQNEGMatchTheArchitecture() async throws {
        // The program is a static aarch64 build of the C beside it (`Tests/Programs/sqabs.c`),
        // mounted from a copy the guest may execute. The expected lines are what the same
        // instructions print on the Mac's own NEON (the C's `-DHOST` build).
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/sqabs")
        let dir = fm.temporaryDirectory.appendingPathComponent("sqabs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("sqabs")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/sqabs-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/sqabs")
        XCTAssertEqual(exit.output, """
            sqabs 8b 0001017f7f7f01010000000000000000
            sqabs 16b 0001017f7f7f0101000000000000007f
            sqabs 4h 0001017f817e01000000000000000000
            sqabs 8h 0001017f817e0100000000000000ff7f
            sqabs 2s 00ff007f817e00000000000000000000
            sqabs 4s 00ff007f817e000000000000ffffff7f
            sqabs 2d 00ff007f807e0000ffffffffffffff7f
            sqneg 8b 00ff017f817f01010000000000000000
            sqneg 16b 00ff017f817f0101000000000000007f
            sqneg 4h 00ff017f817e01000000000000000000
            sqneg 8h 00ff017f817e0100000000000000ff7f
            sqneg 2s 00ff007f817e00000000000000000000
            sqneg 4s 00ff007f817e000000000000ffffff7f
            sqneg 2d 00ff007f807e0000ffffffffffffff7f

            """)
        // The last instruction is SQABS on 1D, which is unallocated: 128 + SIGILL.
        XCTAssertEqual(exit.status, 132, "the unallocated 1D arrangement did not trap")
    }
}
