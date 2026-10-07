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

    /// SQSHLU and UQSHL by immediate (`patches/ish/0010-neon-decode-gaps.patch`): every arrangement
    /// at four shifts, a negative element SQSHLU's zero and a large one saturated, the 64-bit forms'
    /// upper half zeroed, and the unallocated 1D arrangement of each still an illegal instruction.
    /// Claude Code's pixel conversion reaches SQSHLU .8h and its Adler-32 UQSHL .4s.
    func testSQSHLUAndUQSHLByImmediateMatchTheArchitecture() async throws {
        let exit = try await run("qshl")
        XCTAssertEqual(exit.output, """
            sqshlu 8b #0 01000000007f00030000000000000000
            sqshlu 8b #1 0200000000fe00060000000000000000
            sqshlu 8b #4 1000000000ff00300000000000000000
            sqshlu 8b #7 8000000000ff00ff0000000000000000
            sqshlu 16b #0 01000000007f00030000000005000000
            sqshlu 16b #1 0200000000fe0006000000000a000000
            sqshlu 16b #4 1000000000ff00300000000050000000
            sqshlu 16b #7 8000000000ff00ff00000000ff000000
            sqshlu 4h #0 01000000ff7f80030000000000000000
            sqshlu 4h #1 02000000feff00070000000000000000
            sqshlu 4h #8 00010000ffffffff0000000000000000
            sqshlu 4h #15 00800000ffffffff0000000000000000
            sqshlu 8h #0 01000000ff7f80030000000005000000
            sqshlu 8h #1 02000000feff0007000000000a000000
            sqshlu 8h #8 00010000ffffffff0000000000050000
            sqshlu 8h #15 00800000ffffffff00000000ffff0000
            sqshlu 2s #0 01000000ff7f80030000000000000000
            sqshlu 2s #1 02000000feff00070000000000000000
            sqshlu 2s #16 00000100ffffffff0000000000000000
            sqshlu 2s #31 00000080ffffffff0000000000000000
            sqshlu 4s #0 01000000ff7f80030000000000000000
            sqshlu 4s #1 02000000feff00070000000000000000
            sqshlu 4s #6 40000000c0ff1fe00000000000000000
            sqshlu 4s #31 00000080ffffffff0000000000000000
            sqshlu 2d #0 01000000ff7f80030000000000000000
            sqshlu 2d #1 02000000feff00070000000000000000
            sqshlu 2d #32 ffffffffffffffff0000000000000000
            sqshlu 2d #63 ffffffffffffffff0000000000000000
            sqshlu 8h #8 in place 00010000ffffffff0000000000050000
            uqshl 8b #0 01000000ff7f80030000000000000000
            uqshl 8b #1 02000000fffeff060000000000000000
            uqshl 8b #4 10000000ffffff300000000000000000
            uqshl 8b #7 80000000ffffffff0000000000000000
            uqshl 16b #0 01000000ff7f80030000008005000080
            uqshl 16b #1 02000000fffeff06000000ff0a0000ff
            uqshl 16b #4 10000000ffffff30000000ff500000ff
            uqshl 16b #7 80000000ffffffff000000ffff0000ff
            uqshl 4h #0 01000000ff7f80030000000000000000
            uqshl 4h #1 02000000feff00070000000000000000
            uqshl 4h #8 00010000ffffffff0000000000000000
            uqshl 4h #15 00800000ffffffff0000000000000000
            uqshl 8h #0 01000000ff7f80030000008005000080
            uqshl 8h #1 02000000feff00070000ffff0a00ffff
            uqshl 8h #8 00010000ffffffff0000ffff0005ffff
            uqshl 8h #15 00800000ffffffff0000ffffffffffff
            uqshl 2s #0 01000000ff7f80030000000000000000
            uqshl 2s #1 02000000feff00070000000000000000
            uqshl 2s #16 00000100ffffffff0000000000000000
            uqshl 2s #31 00000080ffffffff0000000000000000
            uqshl 4s #0 01000000ff7f80030000008005000080
            uqshl 4s #1 02000000feff0007ffffffffffffffff
            uqshl 4s #6 40000000c0ff1fe0ffffffffffffffff
            uqshl 4s #31 00000080ffffffffffffffffffffffff
            uqshl 2d #0 01000000ff7f80030000008005000080
            uqshl 2d #1 02000000feff0007ffffffffffffffff
            uqshl 2d #32 ffffffffffffffffffffffffffffffff
            uqshl 2d #63 ffffffffffffffffffffffffffffffff
            uqshl 4s #6 in place 40000000c0ff1fe0ffffffffffffffff
            sqshlu 1d SIGILL
            uqshl 1d SIGILL

            """)
        XCTAssertEqual(exit.status, 0)
    }

    /// SCVTF and UCVTF with fractional bits, on vectors (the same patch): the single- and
    /// double-precision arrangements from one fractional bit to as many as the element has, every
    /// conversion rounding once as the instruction does, and the two unallocated forms (an 8-bit
    /// element, the 1D arrangement) and the half-precision ones (a 16-bit element, which the guest
    /// does not report) still illegal instructions. Claude Code reaches both on .2d.
    func testSCVTFAndUCVTFFixedPointMatchTheArchitecture() async throws {
        let exit = try await run("cvtf")
        XCTAssertEqual(exit.output, """
            scvtf 2s #1 0000c03f0000804e0000000000000000
            scvtf 2s #16 00004038000000470000000000000000
            scvtf 2s #32 000040300000003f0000000000000000
            scvtf 4s #1 0000c03f0000804e00007ec2000080ce
            scvtf 4s #16 00004038000000470000feba000000c7
            scvtf 4s #32 000040300000003f0000feb2000000bf
            scvtf 2d #1 0000c0ffffffcf43000080ffffffcfc3
            scvtf 2d #15 0000c0ffffffef42000080ffffffefc2
            scvtf 2d #16 0000c0ffffffdf42000080ffffffdfc2
            scvtf 2d #33 0000c0ffffffcf41000080ffffffcfc1
            scvtf 2d #64 0000c0ffffffdf3f000080ffffffdfbf
            ucvtf 2s #1 0000c03f0000804e0000000000000000
            ucvtf 2s #16 00004038000000470000000000000000
            ucvtf 2s #32 000040300000003f0000000000000000
            ucvtf 4s #1 0000c03f0000804e0000004f0000804e
            ucvtf 4s #16 00004038000000470000804700000047
            ucvtf 4s #32 000040300000003f0000803f0000003f
            ucvtf 2d #1 0000c0ffffffcf43000040000000d043
            ucvtf 2d #15 0000c0ffffffef42000040000000f042
            ucvtf 2d #16 0000c0ffffffdf42000040000000e042
            ucvtf 2d #33 0000c0ffffffcf41000040000000d041
            ucvtf 2d #64 0000c0ffffffdf3f000040000000e03f
            scvtf 8b SIGILL
            scvtf 4h SIGILL
            ucvtf 8h SIGILL

            """)
        // The 8-bit and 16-bit forms each killed a child with SIGILL (the last lines), and the last
        // instruction is UCVTF on 1D, unallocated: 128 + SIGILL.
        XCTAssertEqual(exit.status, 132, "the unallocated 1D arrangement did not trap")
    }

    /// UDOT (the same patch): both arrangements, a sum that wraps, the destination also a source,
    /// and the encoding's three unallocated sizes still illegal instructions. The guest does not
    /// report the dot-product feature, which Claude Code's Adler-32 has UDOT behind.
    func testUDOTMatchesTheArchitecture() async throws {
        let exit = try await run("udot")
        XCTAssertEqual(exit.output, """
            udot 2s aea2aeaaf0aaaaaa0000000000000000
            udot 4s aea2aeaaf0aaaaaaa7ecaaaa9cb6acaa
            udot 2s wraps 03f80300450000000000000000000000
            udot 4s wraps 03f8030045000000fc410000f10b0200
            udot 4s onto n 03f80300470203047d427ffff10b0200
            udot 4s onto m 03f803004b0607087d410301f10c0111
            udot size 0 SIGILL
            udot size 1 SIGILL

            """)
        // The encodings with 8-bit and 16-bit sums each killed a child with SIGILL (the last
        // lines), and the last instruction is the one with 64-bit sums, unallocated too: 128 + SIGILL.
        XCTAssertEqual(exit.status, 132, "the unallocated 64-bit size did not trap")
    }

    /// FNEG on half-precision vectors (the same patch): each 16-bit element's sign bit flipped and
    /// nothing else, zeros, infinities and NaNs included. The guest does not report half-precision
    /// floating point; Claude Code reaches FNEG .8h in code compiled for it.
    func testFNEGHalfPrecisionMatchesTheArchitecture() async throws {
        let exit = try await run("fneg")
        XCTAssertEqual(exit.output, """
            fneg 4h 0080000000fc007c0000000000000000
            fneg 8h 0080000000fc007c01fe017c81803432
            fneg 8h in place 0080000000fc007c01fe017c81803432

            """)
        XCTAssertEqual(exit.status, 0)
    }
}
