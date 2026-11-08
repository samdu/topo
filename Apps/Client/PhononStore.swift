#if os(iOS)
import BackgroundAssets
import Foundation
import System
import TopoCore

private let log = TopoLog(.models)

/// The voice's bundle on this phone: Phonon 40m English exported to Core ML with its one voice,
/// as `PhononVoiceEngine` loads it. One reader for every source a build has — the Apple-hosted
/// asset pack in a TestFlight or App Store build, the app's own resources in a build from the
/// install page (`TOPO_EMBED_VOICES`), a folder a debug launch names — and one copy, in
/// `Application Support/Voice/phonon-40m-en`, because Core ML compiles a `.mlpackage` beside
/// itself and neither the pack nor the app is writable.
///
/// A copy is made into `phonon-40m-en.partial`, every file checked against the size and SHA-256
/// the source's own `bundle.json` names, `bundle.json` and the `.installed` record written last,
/// and only then renamed into place: a copy that fails takes its partial folder with it, and one cut short by
/// the process ending is a partial folder the next copy removes, never a store folder with a file missing. The record names the bundle's `built`
/// stamp and, from a pack, the pack's version, and a store folder is taken as it stands while
/// those match the source's and every file is there at its size. A store folder of an older
/// bundle is replaced through the same path; a source that cannot be read leaves a good store
/// folder in use.
struct PhononStore: Sendable {
    /// The bundle's folder name, in the pack, in the app's resources and in the store.
    static let name = "phonon-40m-en"
    /// The voice the bundle carries, and the one the engine speaks.
    static let voice = "Friendly Octopus"

    let home: URL
    var staging: URL { home.deletingLastPathComponent().appendingPathComponent(Self.name + ".partial", isDirectory: true) }
    var record: URL { home.appendingPathComponent(".installed") }

    init(home: URL) { self.home = home }

    static func standard() -> PhononStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PhononStore(home: support.appendingPathComponent("Voice", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true))
    }

    /// `bundle.json` as far as the store reads it.
    struct Manifest: Decodable, Equatable, Sendable {
        struct File: Decodable, Equatable, Sendable {
            let path: String
            let size: Int64
            let sha256: String
        }
        let built: Int64
        let files: [File]
    }

    /// What the store last installed: the bundle's stamp, from a pack its version, and whether
    /// the pack has been let go since its copy (nil for a folder, which has nothing to let go).
    struct Installed: Codable, Equatable, Sendable {
        let built: Int64
        let version: Int?
        var released: Bool? = nil

        func isCopy(of built: Int64, version: Int?) -> Bool { self.built == built && self.version == version }
    }

    /// The store folder, made from `source` if it is not already that source's bundle. `progress`
    /// hears a pack's download, as a fraction when the system gives one; `copying`, that a copy
    /// has begun. A launch that finds the store whole hears neither.
    func install(from source: any PhononSource, progress: @escaping @Sendable (Double?) -> Void = { _ in },
                 copying: @Sendable () -> Void = {}) async throws -> URL {
        let kept = installed()
        // A whole store of the pack's version is taken without making the pack local, so a pack
        // let go after its copy is not fetched again for nothing; nor is it when the pack's version
        // cannot be read this launch, which leaves the copy here standing for the next.
        if let kept, source.versioned, isWhole() {
            let version = await source.version()
            if version == nil || version == kept.version {
                if version == nil { log.notice("voice: the pack's version could not be read; the copy here stands") }
                await release(kept, from: source)
                return home
            }
        }
        do {
            try await source.makeLocal(progress: progress)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: try source.url(of: "bundle.json")))
            let version = await source.version()
            if let kept, kept.isCopy(of: manifest.built, version: version), isWhole(manifest) {
                await release(kept, from: source)
                return home
            }
            copying()
            try copy(manifest, version: version, from: source)
            await release(Installed(built: manifest.built, version: version, released: source.versioned ? false : nil), from: source)
            return home
        } catch {
            // A good copy of an older bundle still speaks.
            if kept != nil, isWhole() {
                log.error("voice: no new copy was made, keeping the one here: \(String(describing: error))")
                return home
            }
            throw error
        }
    }

    /// Lets a pack go once its copy is the store's, and records that it has: a removal that fails,
    /// or a process that ends before it, is tried again at the next launch that finds the store
    /// whole, so the phone does not keep the weights twice.
    private func release(_ record: Installed, from source: any PhononSource) async {
        guard source.versioned, record.released != true else { return }
        guard await source.copied() else { return }
        var released = record
        released.released = true
        do {
            try JSONEncoder().encode(released).write(to: self.record, options: .atomic)
        } catch {
            log.error("voice: the pack was let go and its record not written: \(String(describing: error))")
        }
    }

    /// The record of what is installed, or nil for none.
    func installed() -> Installed? {
        guard let data = try? Data(contentsOf: record) else { return nil }
        return try? JSONDecoder().decode(Installed.self, from: data)
    }

    /// Whether every file the store's own manifest names is there at its size.
    func isWhole(_ manifest: Manifest? = nil) -> Bool {
        guard let manifest = manifest ?? (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: home.appendingPathComponent("bundle.json"))))
        else { return false }
        return manifest.files.allSatisfy { Self.size(of: home.appendingPathComponent($0.path)) == $0.size }
    }

    /// The copy: every file into the partial folder, checked, then the manifest and the record,
    /// then the rename. Throws `PhononStoreError` naming the file that did not match.
    func copy(_ manifest: Manifest, version: Int?, from source: any PhononSource) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        do {
            try fill(staging, with: manifest, version: version, from: source)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        try fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.excludeFromBackup(home.deletingLastPathComponent())
        // One step from the old copy to the new: a process that ends in it leaves one or the other.
        if fm.fileExists(atPath: home.path) {
            _ = try fm.replaceItemAt(home, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: home)
        }
        log.notice("voice: bundle \(manifest.built) copied into the store")
    }

    private func fill(_ staging: URL, with manifest: Manifest, version: Int?, from source: any PhononSource) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Self.excludeFromBackup(staging)
        for file in manifest.files {
            guard Self.safe(file.path) else { throw PhononStoreError.badPath(file.path) }
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: try source.url(of: file.path), to: target)
            guard Self.size(of: target) == file.size else { throw PhononStoreError.wrongSize(file.path) }
            guard try ModelStore.sha256(of: target) == file.sha256 else { throw PhononStoreError.wrongDigest(file.path) }
        }
        try fm.copyItem(at: try source.url(of: "bundle.json"), to: staging.appendingPathComponent("bundle.json"))
        try JSONEncoder().encode(Installed(built: manifest.built, version: version, released: version == nil ? nil : false))
            .write(to: staging.appendingPathComponent(".installed"), options: .atomic)
    }

    /// A relative path that stays inside the bundle.
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// The weights come back from their source; a backup of them is 200 MB of nothing.
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

enum PhononStoreError: LocalizedError, Equatable {
    case badPath(String)
    case wrongSize(String)
    case wrongDigest(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .badPath(let path): "the voice's bundle names a path outside itself: \(path)"
        case .wrongSize(let path): "the voice's \(path) is not the size its bundle names"
        case .wrongDigest(let path): "the voice's \(path) does not match its digest"
        case .missing(let path): "the voice's \(path) is not in its source"
        }
    }
}

/// Where a build has the voice's bundle.
protocol PhononSource: Sendable {
    /// Brings the bundle onto the phone where it is not: a pack's download, which `progress`
    /// hears. Throws when it cannot.
    func makeLocal(progress: @escaping @Sendable (Double?) -> Void) async throws
    /// A file of the bundle, by its path in the bundle, once it is local.
    func url(of path: String) throws -> URL
    /// Whether the source has a version of its own and a copy to let go: a pack.
    var versioned: Bool { get }
    /// The source's own version where it has one (a pack's), read without making it local; nil
    /// when it cannot be read.
    func version() async -> Int?
    /// The store holds a checked copy: the source's own is let go. Whether it was.
    func copied() async -> Bool
}

/// The bundle as a folder: the app's own resources in a build from the install page, or the
/// folder a debug launch names (`TOPO_DEBUG_VOICE`).
struct FolderSource: PhononSource {
    let folder: URL

    /// The app's own copy, when the build carries one.
    static func embedded(in bundle: Bundle = .main) -> FolderSource? {
        bundle.url(forResource: PhononStore.name, withExtension: nil).map(FolderSource.init(folder:))
    }

    func makeLocal(progress: @escaping @Sendable (Double?) -> Void) async throws {}
    func url(of path: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PhononStoreError.missing(path) }
        return url
    }
    var versioned: Bool { false }
    func version() async -> Int? { nil }
    func copied() async -> Bool { true }
}

/// The Apple-hosted pack (`phonon-40m-en`, essential), which TopoAssets downloads with the app.
struct AssetPackSource: PhononSource {
    let id: String

    init(id: String = PhononStore.name) { self.id = id }

    func makeLocal(progress: @escaping @Sendable (Double?) -> Void) async throws {
        let manager = AssetPackManager.shared
        let pack = try await manager.assetPack(withID: id)
        let watch = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: id) {
                if case .downloading(_, let fraction) = update { progress(fraction.fractionCompleted) }
            }
        }
        defer { watch.cancel() }
        try await manager.ensureLocalAvailability(of: pack)
    }

    func url(of path: String) throws -> URL {
        try AssetPackManager.shared.url(for: FilePath("\(PhononStore.name)/\(path)"))
    }

    var versioned: Bool { true }

    func version() async -> Int? {
        try? await AssetPackManager.shared.assetPack(withID: id).version
    }

    /// The pack's files are in the store now, checked; the pack itself is let go, so the phone
    /// keeps one copy of the weights and not two.
    func copied() async -> Bool {
        do {
            try await AssetPackManager.shared.remove(assetPackWithID: id)
            return true
        } catch {
            log.error("voice: the asset pack could not be removed after its copy, tried again at the next launch: \(String(describing: error))")
            return false
        }
    }
}
#endif
