import CryptoKit
import Foundation
import TopoIsh

/// The tarball a fakefs may be made from: its size and sha256, pinned in the app's manifest
/// (`Apps/Topo/Resources/models.json`, the entry `scripts/model-manifest.sh` writes for Alpine's
/// minirootfs). Nothing else is ever imported.
public struct RootfsPin: Sendable, Equatable {
    public let size: Int64
    public let sha256: String

    public init(size: Int64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

/// What makes a fakefs from a tarball. `directory` does not exist when it is called, and is the
/// whole of what the importer may write.
public protocol FakefsImporter: Sendable {
    func makeFakefs(from tarball: URL, at directory: URL) throws
}

/// The fork's own importer (`fakefs_import`, tools/fakefs.c): every entry's mode, ownership and
/// device number go into `meta.db` as the kernel reads them, which a host-side extract cannot do —
/// it loses the device nodes, which only root can make.
public struct ForkImporter: FakefsImporter {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public init() {}

    public func makeFakefs(from tarball: URL, at directory: URL) throws {
        var reason = [CChar](repeating: 0, count: 512)
        let result = tarball.withUnsafeFileSystemRepresentation { archive in
            directory.withUnsafeFileSystemRepresentation { fakefs in
                topo_ish_import(archive, fakefs, &reason, reason.count)
            }
        }
        guard result == 0 else {
            throw Failure(description: String(decoding: reason.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}

/// The guest's root on disk: a fakefs made once from the pinned tarball and kept. The import runs
/// into a staging directory beside it and is renamed into place when it has finished, so the
/// fakefs's directory existing is the fakefs being whole; a staging directory found at the start
/// of an install is an import a killed process never finished, and is discarded.
public struct RootfsInstaller: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongSize(expected: Int64, got: Int64)
        case wrongDigest
        case unreadable(String)

        public var description: String {
            switch self {
            case .wrongSize(let expected, let got): "the rootfs is \(got) bytes, not \(expected)"
            case .wrongDigest: "the rootfs is not the pinned one (digest mismatch)"
            case .unreadable(let why): "the rootfs could not be read: \(why)"
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The fakefs was already whole; nothing was read.
        case reused
        /// The tarball was verified and imported.
        case imported
    }

    /// The directory the fakefs and its staging directory live in.
    public let directory: URL
    public let importer: any FakefsImporter

    public init(directory: URL, importer: any FakefsImporter = ForkImporter()) {
        self.directory = directory
        self.importer = importer
    }

    /// Where the kernel boots from: `Userland/alpine` under Application Support.
    public static func standard() -> RootfsInstaller {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RootfsInstaller(directory: support.appendingPathComponent("Userland", isDirectory: true))
    }

    public var fakefs: URL { directory.appendingPathComponent("alpine", isDirectory: true) }
    var staging: URL { directory.appendingPathComponent("alpine.importing", isDirectory: true) }

    /// Whether the fakefs is whole: its directory exists, which only the final rename makes true.
    public var isReady: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fakefs.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Makes the fakefs from `tarball` unless it is already whole. The tarball is checked against
    /// `pin` — size, then digest, read here whatever checked it before — and the importer is not
    /// called unless both match. Blocking: the digest reads the whole file and the import writes
    /// thousands, so callers run it off the main thread.
    @discardableResult
    public func install(from tarball: URL, pin: RootfsPin) throws -> Outcome {
        if isReady { return .reused }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try Self.verify(tarball, against: pin)
        do {
            try importer.makeFakefs(from: tarball, at: staging)
            try fm.moveItem(at: staging, to: fakefs)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return .imported
    }

    static func verify(_ tarball: URL, against pin: RootfsPin) throws {
        let size: Int64
        do {
            size = (try FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? Int64) ?? -1
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard size == pin.size else { throw Failure.wrongSize(expected: pin.size, got: size) }
        guard try sha256(of: tarball) == pin.sha256.lowercased() else { throw Failure.wrongDigest }
    }

    static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
