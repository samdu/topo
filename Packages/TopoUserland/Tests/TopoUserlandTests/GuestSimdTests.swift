import XCTest
import TopoUserland

/// SQABS and SQNEG (vector) in the booted guest (`patches/ish/0005-sqabs-sqneg-vector.patch`), as
/// the architecture has them: every arrangement, saturating each type's minimum to its maximum and
/// zeroing the upper half for the 64-bit forms, and the unallocated 1D arrangement of each still an
/// illegal instruction. ugrep's line numbering, which Claude Code's Bash tool runs as `grep`, reaches SQABS.
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
            sqabs 8b 0000007f0101017f0000000000000000
            sqabs 16b 0000007f0101017f000000000000007f
            sqabs 4h 0000ff7fff00ff7f0000000000000000
            sqabs 8h 0000ff7fff00ff7f000000000000ff7f
            sqabs 2s ffffff7f01ffff7f0000000000000000
            sqabs 4s ffffff7f01ffff7f00000000ffffff7f
            sqabs 2d 0000008001ffff7fffffffffffffff7f
            sqneg 8b 0000007fff0101810000000000000000
            sqneg 16b 0000007fff010181000000000000007f
            sqneg 4h 0000ff7fff0001800000000000000000
            sqneg 8h 0000ff7fff000180000000000000ff7f
            sqneg 2s ffffff7fff0000800000000000000000
            sqneg 4s ffffff7fff00008000000000ffffff7f
            sqneg 2d 00000080fe000080ffffffffffffff7f
            sqneg 1d SIGILL

            """)
        // SQNEG on 1D killed its child with SIGILL (the last line), and the last instruction is SQABS
        // on 1D, both unallocated: 128 + SIGILL.
        XCTAssertEqual(exit.status, 132, "the unallocated 1D arrangement did not trap")
    }
}
