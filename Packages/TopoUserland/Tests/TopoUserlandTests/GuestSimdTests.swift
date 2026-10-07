import XCTest
import TopoUserland

/// SQABS and SQNEG (vector) in the booted guest (`patches/ish/0005-sqabs-sqneg-vector.patch`), as
/// the architecture has them: every arrangement, saturating each type's minimum to its maximum and
/// zeroing the upper half for the 64-bit forms, and the unallocated 1D arrangement of each still an
/// illegal instruction. ugrep's line numbering, which Claude Code's Bash tool runs as `grep`, reaches SQABS.
///
/// SMOV to a general register (`patches/ish/0009-smov.patch`) likewise: a negative and a positive
/// element of every size, from both halves of the vector, sign-extended to Wd with the register's
/// upper half zeroed and to Xd, and the two unallocated forms (Wd from an S element, Xd from a D)
/// still illegal instructions. Claude Code's Bun reaches SMOV Wd, Vn.H[0] in a turn.
final class GuestSimdTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    /// Runs `Tests/Programs/<name>`, a static aarch64 build of the C beside it, mounted from a copy
    /// the guest may execute. The lines each test expects are what the same instructions print on
    /// the Mac's own NEON (the C's `-DHOST` build).
    private func run(_ name: String) async throws -> Guest.Exit {
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/\(name)")
        let dir = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent(name)
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/\(name)-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)
        return try await Guest.shared.run("\(point)/\(name)")
    }

    func testSMOVMatchesTheArchitecture() async throws {
        let exit = try await run("smov")
        XCTAssertEqual(exit.output, """
            smov w b[0] 0000000000000000
            smov w b[3] 00000000ffffff80
            smov w b[7] 000000000000007f
            smov w b[9] 00000000ffffff80
            smov w b[15] 00000000ffffff80
            smov w h[0] 0000000000000000
            smov w h[1] 00000000ffff8000
            smov w h[3] 0000000000007fff
            smov w h[4] 00000000ffff807f
            smov w h[7] 00000000ffff8000
            smov x b[3] ffffffffffffff80
            smov x b[8] 000000000000007f
            smov x b[9] ffffffffffffff80
            smov x h[1] ffffffffffff8000
            smov x h[5] 0000000000001234
            smov x h[7] ffffffffffff8000
            smov x s[0] ffffffff80000000
            smov x s[1] 000000007fffff01
            smov x s[2] 000000001234807f
            smov x s[3] ffffffff80000000
            smov w s[0] SIGILL

            """)
        // SMOV Wd from an S element killed its child with SIGILL (the last line), and the last
        // instruction is SMOV Xd from a D element, both unallocated: 128 + SIGILL.
        XCTAssertEqual(exit.status, 132, "the unallocated D element did not trap")
    }

    func testSQABSAndSQNEGMatchTheArchitecture() async throws {
        let exit = try await run("sqabs")
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
