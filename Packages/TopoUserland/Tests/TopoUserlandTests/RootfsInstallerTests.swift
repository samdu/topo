import CryptoKit
import XCTest
@testable import TopoUserland

/// The rootfs pipeline between the downloaded files and a fakefs the kernel can boot: only the
/// pinned tarball and the pinned packages reach the importer, and only a finished import — one that
/// wrote the completion marker — is ever taken for a fakefs.
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
        try file("rootfs.tar.gz", bytes)
    }

    private func file(_ name: String, _ bytes: Data) throws -> (URL, RootfsPin) {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (url, RootfsPin(size: Int64(bytes.count), sha256: digest))
    }

    /// Two stand-in packages, written and pinned.
    private func packages() throws -> [RootfsLayer] {
        try ["bash.apk", "readline.apk"].map {
            let (url, pin) = try file($0, Data($0.utf8))
            return RootfsLayer(file: url, pin: pin)
        }
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

        XCTAssertThrowsError(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages())) { error in
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

        XCTAssertThrowsError(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages())) { error in
            XCTAssertEqual(error as? RootfsInstaller.Failure, .wrongSize(expected: 4096, got: 4000))
        }
        XCTAssertEqual(importer.calls, 0)
        XCTAssertFalse(installer.isReady)
    }

    func testTheImportRunsIntoStagingAndIsRenamedIntoPlace() throws {
        let (url, pin) = try tarball(Data(repeating: 3, count: 1024))
        let packages = try packages()
        let importer = CountingImporter()
        let installer = installer(importer)

        XCTAssertEqual(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: packages), .imported)
        XCTAssertEqual(importer.calls, 1)
        XCTAssertEqual(importer.directories, [installer.staging], "the importer wrote somewhere other than staging")
        XCTAssertEqual(importer.layers, [[url] + packages.map(\.file)], "the importer was not handed the rootfs then the packages")
        XCTAssertTrue(installer.isReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.fakefs.appendingPathComponent("meta.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.staging.path))
        // The marker names every layer imported, by digest.
        let marker = try String(contentsOf: installer.fakefs.appendingPathComponent(RootfsInstaller.marker), encoding: .utf8)
        XCTAssertEqual(marker, ([pin] + packages.map(\.pin)).enumerated().map { index, pin in
            "\(pin.sha256) \(index == 0 ? url.lastPathComponent : packages[index - 1].file.lastPathComponent)\n"
        }.joined())
    }

    func testAPackageWithTheWrongDigestNeverReachesTheImporter() throws {
        let (url, pin) = try tarball(Data(repeating: 4, count: 1024))
        var packages = try packages()
        // The second package swapped for another of the same length after it was pinned.
        try Data("readlinf.apk".utf8).write(to: packages[1].file)
        let importer = CountingImporter()
        let installer = installer(importer)

        XCTAssertThrowsError(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: packages)) { error in
            XCTAssertEqual(error as? RootfsInstaller.Failure, .package("readline.apk", .wrongDigest))
        }
        XCTAssertEqual(importer.calls, 0, "an unverified package reached the importer")
        XCTAssertFalse(installer.isReady)

        // And one truncated.
        packages = try self.packages()
        try Data("bash".utf8).write(to: packages[0].file)
        XCTAssertThrowsError(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: packages)) { error in
            XCTAssertEqual(error as? RootfsInstaller.Failure, .package("bash.apk", .wrongSize(expected: 8, got: 4)))
        }
        XCTAssertEqual(importer.calls, 0)
    }

    /// A fakefs made before the packages were laid in has no marker: it is not taken for whole, and
    /// the install imports afresh from the tarball and the packages and puts the new one in its
    /// place, rather than adding to the old one.
    func testAFakefsWithNoMarkerIsImportedAfresh() throws {
        let (url, pin) = try tarball(Data(repeating: 6, count: 1024))
        let first = installer(CountingImporter())
        let fm = FileManager.default
        try fm.createDirectory(at: first.fakefs.appendingPathComponent("data/bin", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data("an old database".utf8).write(to: first.fakefs.appendingPathComponent("meta.db"))
        try Data("busybox".utf8).write(to: first.fakefs.appendingPathComponent("data/bin/busybox"))
        XCTAssertFalse(first.isReady, "a fakefs with no marker was taken for whole")

        let importer = CountingImporter()
        let relaunched = installer(importer)
        XCTAssertEqual(try relaunched.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages()), .imported)
        XCTAssertEqual(importer.calls, 1)
        XCTAssertEqual(importer.stagingExisted, [false])
        XCTAssertTrue(relaunched.isReady)
        XCTAssertEqual(try Data(contentsOf: relaunched.fakefs.appendingPathComponent("meta.db")), CountingImporter.database,
                       "the old fakefs was patched rather than replaced")
        XCTAssertFalse(fm.fileExists(atPath: relaunched.fakefs.appendingPathComponent("data/bin/busybox").path))
        XCTAssertFalse(fm.fileExists(atPath: relaunched.staging.path))
    }

    /// A process killed after the import finished and the marker was written, but before the
    /// rename, leaves a staging directory that looks whole; it is still discarded and imported
    /// again, since only the rename says the import got to its end. So is the combined archive a
    /// killed import left beside it.
    func testAStagingDirectoryIsDiscardedEvenWithItsMarker() throws {
        let (url, pin) = try tarball(Data(repeating: 8, count: 1024))
        let first = installer(CountingImporter())
        let fm = FileManager.default
        try fm.createDirectory(at: first.staging.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: first.staging.appendingPathComponent("meta.db"))
        try Data("stale".utf8).write(to: first.staging.appendingPathComponent(RootfsInstaller.marker))
        try Data("half an archive".utf8).write(to: first.combined)
        XCTAssertFalse(first.isReady)

        let importer = CountingImporter()
        let relaunched = installer(importer)
        XCTAssertEqual(try relaunched.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages()), .imported)
        XCTAssertEqual(importer.stagingExisted, [false], "the importer was handed the old staging directory")
        XCTAssertEqual(try Data(contentsOf: relaunched.fakefs.appendingPathComponent("meta.db")), CountingImporter.database)
        XCTAssertFalse(fm.fileExists(atPath: relaunched.combined.path), "the stale combined archive survived")
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

        XCTAssertEqual(try relaunched.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages()), .imported)
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
        try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages())
        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages()), .reused)
        XCTAssertEqual(importer.calls, 1)
    }

    func testAFailedImportLeavesNothingThatLooksReady() throws {
        let (url, pin) = try tarball(Data(repeating: 2, count: 1024))
        let importer = CountingImporter(fails: true)
        let installer = installer(importer)

        XCTAssertThrowsError(try installer.install(rootfs: RootfsLayer(file: url, pin: pin), packages: try packages()))
        XCTAssertEqual(importer.calls, 1)
        XCTAssertFalse(installer.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.staging.path))
    }

    /// The fork's own importer on Alpine's minirootfs and the pinned packages, combined into one
    /// archive and imported: a fakefs with the tree under `data/` and its metadata in `meta.db`,
    /// busybox and bash among it and the libraries bash links, and none of a package's control
    /// entries; the combined archive gone once it has been read.
    func testTheForkImporterMakesAFakefsFromThePinnedRootfsAndPackages() throws {
        let layers = try Fixture.layers()
        let installer = RootfsInstaller(directory: directory.appendingPathComponent("Userland", isDirectory: true))

        XCTAssertEqual(try installer.install(rootfs: layers.rootfs, packages: layers.packages), .imported)
        let fm = FileManager.default
        let data = installer.fakefs.appendingPathComponent("data")
        XCTAssertTrue(fm.fileExists(atPath: installer.fakefs.appendingPathComponent("meta.db").path))
        XCTAssertTrue(installer.isReady)
        for path in ["bin/busybox", "etc/alpine-release", "bin/bash", "usr/lib/libreadline.so.8.2",
                     "usr/lib/libncursesw.so.6.5", "etc/terminfo/d/dumb"] {
            XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent(path).path), path)
        }
        for control in [".PKGINFO", ".post-install", ".post-upgrade", ".pre-deinstall"] {
            XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent(control).path), "\(control) was laid into the root")
        }
        let signatures = try fm.contentsOfDirectory(atPath: data.path).filter { $0.hasPrefix(".SIGN") }
        XCTAssertEqual(signatures, [])
        XCTAssertFalse(fm.fileExists(atPath: installer.combined.path), "the combined archive was left behind")
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
    private var _layers: [[URL]] = []

    init(fails: Bool = false) { self.fails = fails }

    var calls: Int { lock.withLock { _calls } }
    var directories: [URL] { lock.withLock { _directories } }
    var stagingExisted: [Bool] { lock.withLock { _stagingExisted } }
    var layers: [[URL]] { lock.withLock { _layers } }

    struct Refused: Error {}

    func makeFakefs(from rootfs: URL, packages: [URL], at directory: URL) throws {
        let existed = FileManager.default.fileExists(atPath: directory.path)
        lock.withLock {
            _calls += 1
            _directories.append(directory)
            _stagingExisted.append(existed)
            _layers.append([rootfs] + packages)
        }
        // As fakefs_import: it makes the directory itself, and fails if it is already there.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("data", isDirectory: true),
                                                withIntermediateDirectories: true)
        if fails { throw Refused() }
        try Self.database.write(to: directory.appendingPathComponent("meta.db"))
    }
}
