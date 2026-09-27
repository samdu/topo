import CryptoKit
import Foundation
import TopoUserland
import XCTest

@testable import TopoUserland

/// `op` is handed a token only once it is the pinned build: the installer extracts it when the
/// directory holds no binary at its pin, checks what came out, and makes executable only a file
/// that matches.
final class OnePasswordInstallerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("op-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let good = Data("the pinned op".utf8)

    private func pin(for data: Data) -> ClaudeCodePin {
        ClaudeCodePin(version: "2.39.0", size: Int64(data.count),
                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func installer() throws -> OnePasswordInstaller {
        let zip = root.appendingPathComponent("zip/op_linux_arm64_v2.39.0.zip")
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: zip)
        return OnePasswordInstaller(zip: zip, directory: root.appendingPathComponent("op-cli"), pin: pin(for: good))
    }

    private func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0
    }

    /// The two halves of an install, with the guest's extraction between them as `write` does it.
    private func install(_ installer: OnePasswordInstaller, into mounts: CountingMounts,
                         extraction write: () throws -> (status: Int32, errors: String)) throws {
        if try installer.mount(into: mounts) {
            try installer.complete(extracted: try write())
        } else {
            try installer.complete(extracted: nil)
        }
    }

    func testExtractsVerifiesAndMakesExecutable() throws {
        let installer = try installer()
        let mounts = CountingMounts()
        XCTAssertEqual(installer.extraction, "unzip -o -q '/opt/op-cli-zip/op_linux_arm64_v2.39.0.zip' op -d '/opt/op-cli'")
        var extractions = 0
        try install(installer, into: mounts) {
            extractions += 1
            try self.good.write(to: installer.binary)
            return (0, "")
        }
        XCTAssertEqual(extractions, 1)
        XCTAssertEqual(mounts.mounts.map(\.point), [OnePasswordInstaller.mountPoint, OnePasswordInstaller.zipMountPoint])
        XCTAssertEqual(try mode(installer.binary) & 0o111, 0o111)
        XCTAssertTrue(mounts.links.isEmpty, "op is not put on the guest's path")
    }

    func testABinaryAlreadyAtItsPinIsNotExtractedAgain() throws {
        let installer = try installer()
        try FileManager.default.createDirectory(at: installer.directory, withIntermediateDirectories: true)
        try good.write(to: installer.binary)
        let mounts = CountingMounts()
        try install(installer, into: mounts) {
            XCTFail("extracted a binary already at its pin")
            return (1, "")
        }
        XCTAssertEqual(mounts.mounts.map(\.point), [OnePasswordInstaller.mountPoint])
        XCTAssertEqual(try mode(installer.binary) & 0o111, 0o111)
    }

    func testAnExtractedBinaryNotAtItsPinIsNotMadeExecutable() throws {
        let installer = try installer()
        XCTAssertThrowsError(try install(installer, into: CountingMounts()) {
            try Data("something else entirely".utf8).write(to: installer.binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.binary.path)
            return (0, "")
        }) { error in
            XCTAssertEqual(error as? OnePasswordInstaller.Failure, .wrongSize(expected: Int64(good.count), got: 23))
        }
        XCTAssertEqual(try mode(installer.binary) & 0o111, 0, "a binary nobody pinned is left not executable")
    }

    func testASameSizedBinaryWithAnotherDigestIsRefused() throws {
        let installer = try installer()
        XCTAssertThrowsError(try install(installer, into: CountingMounts()) {
            try Data("the pinned oq".utf8).write(to: installer.binary)
            return (0, "")
        }) { error in
            XCTAssertEqual(error as? OnePasswordInstaller.Failure, .wrongDigest)
        }
        XCTAssertEqual(try mode(installer.binary) & 0o111, 0)
    }

    func testAFailedExtractionSaysWhy() throws {
        let installer = try installer()
        XCTAssertThrowsError(try install(installer, into: CountingMounts()) { (9, "unzip: short read") }) { error in
            XCTAssertEqual(error as? OnePasswordInstaller.Failure, .extraction("unzip: short read"))
        }
    }
}
