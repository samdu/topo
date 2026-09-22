import CryptoKit
import XCTest
@testable import TopoUserland

/// The rootfs pipeline between a downloaded file and a fakefs the kernel can boot: only the pinned
/// tarball reaches the importer, and only a finished import is ever taken for a fakefs.
final class RootfsInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `bytes` as a tarball and returns it with the pin that matches it.
    private func tarball(_ bytes: Data) throws -> (URL, RootfsPin) {
        let url = directory.appendingPathComponent("rootfs.tar.gz")
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (url, RootfsPin(size: Int64(bytes.count), sha256: digest))
    }

    private func installer(_ importer: CountingImporter) -> RootfsInstaller {
        RootfsInstaller(directory: directory.appendingPathComponent("Userland", isDirectory: true), importer: importer)
    }

    func testATarballOfThePinnedSizeWithTheWrongDigestNeverReachesTheImporter() throws {
        let (url, pin) = try tarball(Data(repeating: 7, count: 4096))
        // Same size, one byte different: what a swapped or corrupted file at the pinned length is.
        var other = Data(repeating: 7, count: 4096)
        other[100] = 8
        try other.write(to: url)
        let importer = CountingImporter()
        let installer = installer(importer)

        XCTAssertThrowsError(try installer.install(from: url, pin: pin)) { error in
            XCTAssertEqual(error as? RootfsInstaller.Failure, .wrongDigest)
        }
        XCTAssertEqual(importer.calls, 0, "unverified bytes reached the importer")
        XCTAssertFalse(installer.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.staging.path))
    }

    func testATruncatedTarballNeverReachesTheImporter() throws {
        let bytes = Data(repeating: 1, count: 4096)
        let (url, pin) = try tarball(bytes)
        try bytes.prefix(4000).write(to: url)
        let importer = CountingImporter()
        let installer = installer(importer)

        XCTAssertThrowsError(try installer.install(from: url, pin: pin)) { error in
            XCTAssertEqual(error as? RootfsInstaller.Failure, .wrongSize(expected: 4096, got: 4000))
        }
        XCTAssertEqual(importer.calls, 0)
        XCTAssertFalse(installer.isReady)
    }

    func testTheImportRunsIntoStagingAndIsRenamedIntoPlace() throws {
        let (url, pin) = try tarball(Data(repeating: 3, count: 1024))
        let importer = CountingImporter()
        let installer = installer(importer)

        XCTAssertEqual(try installer.install(from: url, pin: pin), .imported)
        XCTAssertEqual(importer.calls, 1)
        XCTAssertEqual(importer.directories, [installer.staging], "the importer wrote somewhere other than staging")
        XCTAssertTrue(installer.isReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.fakefs.appendingPathComponent("meta.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.staging.path))
    }

    func testAPartialImportLeftByAKilledProcessIsDiscardedAndRunAgain() throws {
        let (url, pin) = try tarball(Data(repeating: 5, count: 1024))
        // What a process killed mid-import leaves: a staging directory with half a database and
        // half a tree in it, and no fakefs.
        let first = installer(CountingImporter())
        let fm = FileManager.default
        try fm.createDirectory(at: first.staging.appendingPathComponent("data/bin", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data("half a database".utf8).write(to: first.staging.appendingPathComponent("meta.db"))
        try Data("half a file".utf8).write(to: first.staging.appendingPathComponent("data/bin/partial"))

        // The relaunch: a new installer over the same directory.
        let importer = CountingImporter()
        let relaunched = installer(importer)
        XCTAssertFalse(relaunched.isReady, "a partial import was taken for a whole fakefs")

        XCTAssertEqual(try relaunched.install(from: url, pin: pin), .imported)
        XCTAssertEqual(importer.calls, 1, "the import did not run again")
        XCTAssertEqual(importer.stagingExisted, [false], "the importer was handed the partial directory")
        XCTAssertTrue(relaunched.isReady)
        XCTAssertFalse(fm.fileExists(atPath: relaunched.fakefs.appendingPathComponent("data/bin/partial").path),
                       "the partial import survived into the fakefs")
        XCTAssertEqual(try Data(contentsOf: relaunched.fakefs.appendingPathComponent("meta.db")), CountingImporter.database)
    }

    func testAWholeFakefsIsReusedWithoutReadingTheTarball() throws {
        let (url, pin) = try tarball(Data(repeating: 9, count: 1024))
        let importer = CountingImporter()
        let installer = installer(importer)
        try installer.install(from: url, pin: pin)
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(try installer.install(from: url, pin: pin), .reused)
        XCTAssertEqual(importer.calls, 1)
    }

    func testAFailedImportLeavesNothingThatLooksReady() throws {
        let (url, pin) = try tarball(Data(repeating: 2, count: 1024))
        let importer = CountingImporter(fails: true)
        let installer = installer(importer)

        XCTAssertThrowsError(try installer.install(from: url, pin: pin))
        XCTAssertEqual(importer.calls, 1)
        XCTAssertFalse(installer.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.staging.path))
    }

    /// The fork's own importer on Alpine's minirootfs: a fakefs with the tree under `data/` and its
    /// metadata in `meta.db`, busybox among it.
    func testTheForkImporterMakesAFakefsFromThePinnedRootfs() throws {
        let rootfs = try Fixture.rootfs()
        let installer = RootfsInstaller(directory: directory.appendingPathComponent("Userland", isDirectory: true))

        XCTAssertEqual(try installer.install(from: rootfs.url, pin: rootfs.pin), .imported)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: installer.fakefs.appendingPathComponent("meta.db").path))
        XCTAssertTrue(fm.fileExists(atPath: installer.fakefs.appendingPathComponent("data/bin/busybox").path))
        XCTAssertTrue(fm.fileExists(atPath: installer.fakefs.appendingPathComponent("data/etc/alpine-release").path))
    }
}

/// An importer that counts its calls and writes a stand-in fakefs, or throws.
final class CountingImporter: FakefsImporter, @unchecked Sendable {
    static let database = Data("a whole database".utf8)
    private let lock = NSLock()
    private let fails: Bool
    private var _calls = 0
    private var _directories: [URL] = []
    private var _stagingExisted: [Bool] = []

    init(fails: Bool = false) { self.fails = fails }

    var calls: Int { lock.withLock { _calls } }
    var directories: [URL] { lock.withLock { _directories } }
    var stagingExisted: [Bool] { lock.withLock { _stagingExisted } }

    struct Refused: Error {}

    func makeFakefs(from tarball: URL, at directory: URL) throws {
        let existed = FileManager.default.fileExists(atPath: directory.path)
        lock.withLock {
            _calls += 1
            _directories.append(directory)
            _stagingExisted.append(existed)
        }
        // As fakefs_import: it makes the directory itself, and fails if it is already there.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data", isDirectory: true),
                                                withIntermediateDirectories: true)
        if fails { throw Refused() }
        try Self.database.write(to: directory.appendingPathComponent("meta.db"))
    }
}
