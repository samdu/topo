import XCTest
import TopoUserland

/// `pidfd_open` in the booted guest, as Linux has it (`patches/ish/0003-pidfd-open-zombie.patch`):
/// a child that has exited and not been reaped opens and reads as exited, a reaped one is `ESRCH`,
/// and a running one opens and does not. Claude Code's runtime opens a pidfd on every child it
/// spawns, and a child quick enough to exit first used to be `ESRCH`, which sent that runtime
/// down a path that ended its own stdin before it read a byte of it.
final class GuestPidfdTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testAZombieOpensAndReadsAsExitedAReapedOneIsGoneAndALiveOneDoesNotRead() async throws {
        // The program is a static aarch64 build of the C beside it (`Tests/Programs/pidfd.c`),
        // mounted from a copy the guest may execute.
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/pidfd")
        let dir = fm.temporaryDirectory.appendingPathComponent("pidfd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("pidfd")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/pidfd-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/pidfd")
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.output, "zombie=open readable=1 reaped=-3 live=open readable=0\n")
    }
}
