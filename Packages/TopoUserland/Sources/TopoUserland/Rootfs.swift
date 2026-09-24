import CryptoKit
import Foundation
import TopoIsh

/// A file a fakefs may be made from — the rootfs tarball or one of Alpine's packages laid in
/// beside it — by its size and sha256, pinned in the app's manifest (`Apps/Topo/Resources/models.json`,
/// the entries `scripts/model-manifest.sh` writes for Alpine's minirootfs and for bash and its
/// dependencies). Nothing else is ever imported.
public struct RootfsPin: Sendable, Equatable {
    public let size: Int64
    public let sha256: String

    public init(size: Int64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

/// A downloaded file and the pin it is checked against before the importer sees it.
public struct RootfsLayer: Sendable, Equatable {
    public let file: URL
    public let pin: RootfsPin

    public init(file: URL, pin: RootfsPin) {
        self.file = file
        self.pin = pin
    }
}

/// What makes a fakefs from the rootfs tarball and the packages laid into it. `directory` does not
/// exist when it is called, and is the whole of what the importer may write, beside one scratch
/// file at `directory` plus `.tar` that it removes before it returns.
public protocol FakefsImporter: Sendable {
    func makeFakefs(from rootfs: URL, packages: [URL], at directory: URL) throws
}

/// The fork's own importer (`fakefs_import`, tools/fakefs.c): every entry's mode, ownership and
/// device number go into `meta.db` as the kernel reads them, which a host-side extract cannot do —
/// it loses the device nodes, which only root can make. It makes a new fakefs from one archive, so
/// the rootfs and the packages are first written as one (`topo_ish_combine`: the rootfs whole,
/// then each package's files less its control entries, headers as the archives carry them) and
/// that one archive is imported; a later entry for a path an earlier one made replaces it, as an
/// install over it would.
public struct ForkImporter: FakefsImporter {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public init() {}

    public func makeFakefs(from rootfs: URL, packages: [URL], at directory: URL) throws {
        guard !packages.isEmpty else { return try Self.importArchive(rootfs, at: directory) }
        let combined = URL(fileURLWithPath: directory.path + ".tar")
        try? FileManager.default.removeItem(at: combined)
        defer { try? FileManager.default.removeItem(at: combined) }
        try Self.combine(rootfs, packages, into: combined)
        try Self.importArchive(combined, at: directory)
    }

    static func combine(_ rootfs: URL, _ packages: [URL], into out: URL) throws {
        var reason = [CChar](repeating: 0, count: 512)
        let paths = packages.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        let result = paths.map { UnsafePointer($0) }.withUnsafeBufferPointer { list in
            rootfs.withUnsafeFileSystemRepresentation { rootfs in
                out.withUnsafeFileSystemRepresentation { out in
                    topo_ish_combine(rootfs, list.baseAddress, list.count, out, &reason, reason.count)
                }
            }
        }
        guard result == 0 else { throw Failure(description: Self.text(reason)) }
    }

    static func importArchive(_ archive: URL, at directory: URL) throws {
        var reason = [CChar](repeating: 0, count: 512)
        let result = archive.withUnsafeFileSystemRepresentation { archive in
            directory.withUnsafeFileSystemRepresentation { fakefs in
                topo_ish_import(archive, fakefs, &reason, reason.count)
            }
        }
        guard result == 0 else { throw Failure(description: Self.text(reason)) }
    }

    private static func text(_ reason: [CChar]) -> String {
        String(decoding: reason.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The guest's root on disk: a fakefs made once from the pinned rootfs and the pinned packages
/// laid into it, and kept. The import runs into a staging directory beside it; when every layer is
/// in, a completion marker is written inside the staging directory, and the directory is renamed
/// into place with the marker in it. So the fakefs is whole exactly when its directory holds the
/// marker: a staging directory found at the start of an install is an import a killed process never
/// finished, and is discarded, and a fakefs with no marker — one made before the packages were
/// laid in — is imported afresh from the tarball and the packages, never patched in place.
public struct RootfsInstaller: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongSize(expected: Int64, got: Int64)
        case wrongDigest
        case unreadable(String)
        /// A package that failed its pin, by file name, with how.
        indirect case package(String, Failure)

        public var description: String {
            switch self {
            case .wrongSize(let expected, let got): "the rootfs is \(got) bytes, not \(expected)"
            case .wrongDigest: "the rootfs is not the pinned one (digest mismatch)"
            case .unreadable(let why): "the rootfs could not be read: \(why)"
            case .package(let name, .wrongSize(let expected, let got)): "\(name) is \(got) bytes, not \(expected)"
            case .package(let name, .wrongDigest): "\(name) is not the pinned one (digest mismatch)"
            case .package(let name, .unreadable(let why)): "\(name) could not be read: \(why)"
            case .package(let name, let failure): "\(name): \(failure)"
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The fakefs was already whole; nothing was read.
        case reused
        /// The tarball and the packages were verified and imported.
        case imported
    }

    /// The completion marker's name, inside the fakefs's directory beside `meta.db` and `data/` —
    /// outside `data/`, so the guest never sees it. It lists the layers imported, one
    /// `<sha256> <file name>` line each.
    public static let marker = "topo-userland"

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
    /// The combined archive the fork's importer writes beside staging while it runs.
    var combined: URL { URL(fileURLWithPath: staging.path + ".tar") }

    /// Whether the fakefs is whole: its directory holds the completion marker, which only an import
    /// that laid every layer in writes, before the rename that puts it in place.
    public var isReady: Bool {
        var isDirectory: ObjCBool = false
        let marker = fakefs.appendingPathComponent(Self.marker)
        return FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Makes the fakefs from `rootfs` and `packages` unless it is already whole. Each file is
    /// checked against its pin — size, then digest, read here whatever checked it before — and the
    /// importer is not called unless every one matches. A fakefs directory without the marker is
    /// replaced only once the new one is whole. Blocking: the digests read every file and the
    /// import writes thousands, so callers run it off the main thread.
    @discardableResult
    public func install(rootfs: RootfsLayer, packages: [RootfsLayer]) throws -> Outcome {
        if isReady { return .reused }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        if fm.fileExists(atPath: combined.path) {
            try fm.removeItem(at: combined)
        }
        try Self.verify(rootfs.file, against: rootfs.pin)
        for package in packages {
            do {
                try Self.verify(package.file, against: package.pin)
            } catch let failure as Failure {
                throw Failure.package(package.file.lastPathComponent, failure)
            }
        }
        do {
            try importer.makeFakefs(from: rootfs.file, packages: packages.map(\.file), at: staging)
            let layers = ([rootfs] + packages).map { "\($0.pin.sha256.lowercased()) \($0.file.lastPathComponent)\n" }.joined()
            try Data(layers.utf8).write(to: staging.appendingPathComponent(Self.marker), options: .atomic)
            if fm.fileExists(atPath: fakefs.path) {
                try fm.removeItem(at: fakefs)
            }
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
