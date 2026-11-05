#if os(iOS)
import Foundation
import TopoCore
import MachO
import OSLog

private let log = TopoLog(.models)

extension ModelStore {
    /// The ledger's name inside every model's directory.
    static let ledgerName = ".verified.json"
    /// What `resumeData(for:in:)` appends to a file's path.
    static let resumeSuffix = ".resume"

    /// Whether Topo owns the model's directory: a home under `root`. A home elsewhere is a
    /// library's (the CTC spotter under FluidAudio's own cache), and holds files that library
    /// writes for itself, so no sweep enters it.
    func owns(_ model: ModelManifest.Model) -> Bool {
        let home = Self.components(directory(for: model))
        let root = Self.components(root)
        return home.count > root.count && Array(home.prefix(root.count)) == root
    }

    /// Removes what the manifest does not account for, and returns what went. The protected set
    /// is every manifest entry's directory as `directory(for:)` resolves it, never its id: the
    /// voice's id is `pocket-tts-coreml` and its home is `Models/pocket-tts`. Under `root`,
    /// anything that is not one of those homes (or a folder on the way down to one) is removed.
    /// Inside a home Topo owns, of a model that is present — every manifest file on disk at its
    /// size and in the ledger, the downloader's own definition — anything that is not a manifest
    /// file, the ledger or a file's resume data is removed. A model that is not present is left
    /// alone whole, and neither a library's home nor a home that is a link is ever entered.
    @discardableResult
    func sweep(_ manifest: ModelManifest) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        func remove(_ url: URL) {
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                log.error("sweep: could not remove \(url.path): \(error.localizedDescription)")
            }
        }

        // Nothing is removed or entered behind a link: `root` reached through one is somewhere
        // else's folder, and the sweep does nothing at all.
        guard !linkOnChain(from: anchor, to: root) else {
            log.error("sweep: \(root.path) is reached through a link; nothing swept")
            return []
        }

        // The first name beneath `root` of every home that lives under it.
        let rootPath = Self.components(root)
        let protected = Set(manifest.models.compactMap { model -> String? in
            let home = Self.components(directory(for: model))
            guard home.count > rootPath.count, Array(home.prefix(rootPath.count)) == rootPath else { return nil }
            return home[rootPath.count]
        })
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where !protected.contains(entry.lastPathComponent) {
            remove(entry)
        }

        for model in manifest.models where owns(model) && !reachedThroughLink(model) && isPresent(model) {
            var kept: Set<String> = [Self.ledgerName]
            for file in model.files {
                kept.insert(file.path)
                kept.insert(file.path + Self.resumeSuffix)
            }
            // Every folder on the way down to a kept file.
            var ancestors: Set<String> = []
            for path in kept {
                var parts = path.split(separator: "/").map(String.init)
                while parts.count > 1 {
                    parts.removeLast()
                    ancestors.insert(parts.joined(separator: "/"))
                }
            }
            func walk(_ directory: URL, _ prefix: String) {
                for entry in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    let relative = prefix.isEmpty ? entry.lastPathComponent : prefix + "/" + entry.lastPathComponent
                    if kept.contains(relative) { continue }
                    // `lstat`: a link is a link, never the folder it names, so it is removed as
                    // one and never descended.
                    if fileType(entry) == S_IFDIR, ancestors.contains(relative) {
                        walk(entry, relative)
                    } else {
                        remove(entry)
                    }
                }
            }
            walk(directory(for: model), "")
        }

        for url in removed { log.notice("sweep: removed \(url.path)") }
        return removed
    }

    /// Where the chain every sweep judges starts: the folder `root` sits in, which is
    /// Application Support on the phone.
    var anchor: URL { root.deletingLastPathComponent() }

    /// Whether the model's home, or any folder from `anchor` down to it, is a symbolic link. A
    /// home behind a link is somewhere else's folder: the sweep never enters it and leaves the
    /// link where it is.
    func reachedThroughLink(_ model: ModelManifest.Model) -> Bool {
        linkOnChain(from: anchor, to: directory(for: model))
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }
}

/// The Neural Engine's compiled bundles for the models, which CoreML writes under the app's
/// Caches on a model's first load and reuses after: kept across installs, so that an update whose
/// models are the same bytes may skip compiling them again, if CoreML's key for a compiled bundle
/// survives the install (unmeasured; #543's device check), and one per OS build or model pack
/// that differs until iOS purges Caches. Removed whole only when the person asks
/// (`Clear compiled model cache` in the settings sheet), and then at the next launch, before any
/// model loads (`ModelHousekeeping.launch`), so no compile is writing into it as it goes; iOS
/// purges Caches under pressure besides. Nothing else in Caches is touched.
struct CompileCache {
    /// The install the launch last saw, so a new one is logged once.
    static let recorded = "topo.models.compileCacheInstall"
    /// Set by the settings sheet's button: the next launch removes the cache. Removed only once
    /// the directory is gone or was never there, so a removal that fails is tried again.
    static let requested = "topo.models.clearCompileCache"

    let directory: URL
    let defaults: UserDefaults
    let remove: (URL) throws -> Void

    init(directory: URL, defaults: UserDefaults = .standard,
         remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.directory = directory
        self.defaults = defaults
        self.remove = remove
    }

    /// `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`, exactly.
    static func directory(caches: URL, bundleIdentifier: String) -> URL {
        caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
    }

    static func standard() -> CompileCache? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return CompileCache(directory: directory(caches: caches, bundleIdentifier: id))
    }

    enum Outcome: Equatable {
        /// No clear asked for, and the install recorded is this one: nothing done.
        case sameInstall
        /// No clear asked for, and a new install: the cache stands, and the install is recorded.
        case kept
        /// A clear was asked for and the directory removed.
        case cleared
        /// A clear was asked for and there was no directory.
        case absent
        /// The removal threw or was refused; the request stands, so the next launch tries again.
        case failed(String)
    }

    /// What a launch that keeps the cache logs, once per process: so a log read after a relaunch
    /// still says the cache was kept, and whether this launch was the install's first.
    static func kept(install: String, new: Bool) -> String {
        "compile cache: kept for install \(install)\(new ? " (new install)" : "")"
    }

    /// The launch's word on the cache: removes it when a clear was asked for, and otherwise
    /// leaves it and says so.
    @discardableResult
    func launch(install: String) -> Outcome {
        let newInstall = defaults.string(forKey: Self.recorded) != install
        if newInstall { defaults.set(install, forKey: Self.recorded) }
        guard defaults.bool(forKey: Self.requested) else {
            log.notice("\(Self.kept(install: install, new: newInstall))")
            return newInstall ? .kept : .sameInstall
        }
        // Caches, and the app's folder in it, judged with `lstat`: a folder behind a link is
        // somewhere else's, so nothing is removed. The cache folder itself, were it a link, is
        // removed as a link, which touches nothing behind it.
        let parent = directory.deletingLastPathComponent()
        if linkOnChain(from: parent.deletingLastPathComponent(), to: parent) {
            log.error("compile cache: \(parent.path) is reached through a link; not cleared")
            return .failed("reached through a link")
        }
        let outcome: Outcome
        do {
            try remove(directory)
            outcome = .cleared
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            outcome = .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            outcome = .absent
        } catch {
            log.error("compile cache: not cleared, retried next launch: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        defaults.removeObject(forKey: Self.requested)
        log.notice("compile cache: \(outcome == .cleared ? "cleared" : "absent") on request")
        return outcome
    }

    /// What every install changes: the image's `LC_UUID` and the path of the app bundle. The
    /// bundle's container directory is made new by every install, so a byte-identical build
    /// installed over itself is a new key too; the UUID is there so that a build is never
    /// mistaken for another whatever its path. `CFBundleVersion` is no part of it, since every
    /// development install carries 1. Should the bundle's path ever move on a plain launch, the
    /// cost is one extra log line.
    static func installKey() -> String? {
        guard let image = imageUUID() else { return nil }
        return installKey(image: image, bundle: Bundle.main.bundleURL)
    }

    static func installKey(image: String, bundle: URL) -> String {
        "\(image) \(bundle.standardizedFileURL.path)"
    }

    /// The `LC_UUID` of the image this code is linked into. ld writes it from a hash of the
    /// image, so any build that changes the code changes it. In a release build the image is the
    /// main executable; in a debug build Xcode links the app's code into `Topo.debug.dylib`
    /// beside a stub executable that barely changes, which is why this reads the image holding
    /// this code rather than image zero.
    static func imageUUID() -> String? {
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = #dsohandle.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}

/// The file type of `url` itself, by `lstat`, so a link is `S_IFLNK` and never what it names.
/// Nil when there is nothing there.
func fileType(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}

/// Whether any directory from `anchor` down to `url`, both included, is a symbolic link. A
/// `url` that is not `anchor` or beneath it counts as one, since nothing can be said of the way
/// to it. What is not there yet is no link.
func linkOnChain(from anchor: URL, to url: URL) -> Bool {
    let top = anchor.standardizedFileURL.pathComponents
    let path = url.standardizedFileURL.pathComponents
    guard path.count >= top.count, Array(path.prefix(top.count)) == top else { return true }
    var step = anchor
    if fileType(step) == S_IFLNK { return true }
    for name in path[top.count...] {
        step = step.appendingPathComponent(name)
        if fileType(step) == S_IFLNK { return true }
    }
    return false
}

enum ModelHousekeeping {
    /// The launch's first word on the models, in order: the compile cache is cleared if the
    /// person asked, and only then are the ear and the voice made, since a debug build's may start
    /// loading as they are made. Their `prepare` runs on the foreground, from the scene's body,
    /// which SwiftUI only evaluates after the app's `init` has returned.
    @MainActor
    static func launch<Ear, Voice>(clear: () -> Void, ear: () -> Ear, voice: () -> Voice) -> (Ear, Voice) {
        clear()
        return (ear(), voice())
    }

    /// The cache's launch step as the app runs it, which clears only when asked: this install's key against the standard
    /// cache. An image whose key cannot be read is logged as an install of its own.
    static func clearCompileCache() {
        guard let cache = CompileCache.standard() else {
            log.error("compile cache: no bundle id; not looked at")
            return
        }
        cache.launch(install: CompileCache.installKey() ?? "unknown")
    }
}
#endif
