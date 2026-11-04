import XCTest
import TopoUserland

/// `preadv2` and `pwritev2` at offset -1 in the booted guest as a 64-bit Linux reads them
/// (`patches/ish/0017-pv-offset-64.patch`): the offset whole from its low register and the high one
/// ignored, so a pipe takes a stream write and gives a stream read whether the high register holds
/// 0, as Zig's std passes it, or -1, as musl does. Claude Code's Bun writes its stdout through Zig's
/// `pwritev2`, and with the offset read from both halves every line it wrote to a pipe was refused,
/// so the app heard nothing from a turn the resident had answered.
final class GuestStreamOffsetTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testAPipeTakesAStreamWriteAndReadWhateverTheHighRegisterHolds() async throws {
        // The program is a static aarch64 build of the C beside it (`Tests/Programs/pv.c`),
        // mounted from a copy the guest may execute.
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/pv")
        let dir = fm.temporaryDirectory.appendingPathComponent("pv-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("pv")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/pv-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/pv")
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "zig write=4 read=4 same musl write=4 read=4 same\n")
    }
}
