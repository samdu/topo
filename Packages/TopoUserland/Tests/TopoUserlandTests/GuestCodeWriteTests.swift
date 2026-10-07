import XCTest
import TopoUserland

/// Several guest threads writing to pages holding translated code while that code, and the code on
/// the pages sharing its page-hash buckets, is being run (`Tests/Programs/codewrite.c`): four
/// threads, each with two copies of a chain of four pages joined by direct branches, every chain
/// 1024 pages from the next so page i of each shares a bucket with page i of the rest. A thread
/// patches one page of one copy, runs both copies and compares every lane with what it wrote; a
/// thread's write invalidates every thread's blocks for that page, chained predecessors included,
/// under the others' feet. Only the owner runs its chains, so what it reads back is deterministic.
/// The whole app is the process the guest runs in, so an emulator fault here fails the run, not
/// only the assertion.
final class GuestCodeWriteTests: XCTestCase {
    private let fm = FileManager.default
    private var host: URL?

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        if let host { try? fm.removeItem(at: host) }
    }

    func testThreadsWritingToPagesOfTranslatedCodeRunWhatTheyWrote() async throws {
        // The program is a static aarch64 build of the C beside it, mounted from a copy the guest
        // may execute.
        let program = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs/codewrite")
        let dir = fm.temporaryDirectory.appendingPathComponent("codewrite-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        host = dir
        let copy = dir.appendingPathComponent("codewrite")
        try fm.copyItem(at: program, to: copy)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let point = "/opt/codewrite-\(UUID().uuidString.prefix(8))"
        try Guest.shared.mount(dir, at: point)

        let exit = try await Guest.shared.run("\(point)/codewrite")
        XCTAssertEqual(exit.output, "rounds=20000 threads=4 copies=2 mismatches=0\n", exit.errors)
        XCTAssertEqual(exit.status, 0)
        // The emulator chains a block's exit only to a block below 4 GB, so the chains have to sit
        // there for the test to be of chained code at all; the program says where they went.
        let region = exit.errors.split(separator: "\n").first { $0.hasPrefix("region=0x") }
            .flatMap { UInt64($0.dropFirst("region=0x".count), radix: 16) }
        XCTAssertNotNil(region, exit.errors)
        XCTAssertLessThan(region ?? .max, 1 << 32, "the chains are above 4 GB, where nothing chains")
    }
}
