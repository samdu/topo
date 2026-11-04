import XCTest
import TopoUserland

/// The signal frame's ucontext in the booted guest as Linux lays it out on arm64
/// (`patches/ish/0016-ucontext-mcontext-offset.patch`): `uc_mcontext` at 176 and 16-byte aligned,
/// the interrupted stack pointer at 432 and pc at 440, and the FPSIMD record at the mcontext's 288,
/// with the handler's return landing back after the `svc` that raised it. Claude Code's Bun judges
/// whether a thread it suspends for its collector is on its own stack by that stack pointer, so a
/// frame that put it anywhere else left every turn spinning on a thread that never suspended.
final class GuestSignalFrameTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testTheHandlerReadsTheInterruptedStackAndPcWhereLinuxPutsThem() async throws {
        // The program is a static aarch64 build of the C beside it (`Tests/Programs/ucontext.c`),
        // mounted from a copy the guest may execute.
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/ucontext")
        let dir = fm.temporaryDirectory.appendingPathComponent("ucontext-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("ucontext")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/ucontext-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/ucontext")
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "sp=ok pc=ok aligned=ok fpsimd=ok returned\n")
    }
}
