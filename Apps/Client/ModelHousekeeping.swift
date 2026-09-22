#if os(iOS)
import Foundation
import MachO
import OSLog

private let log = Logger(subsystem: "zone.hexagon.topo", category: "models")

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
                log.error("sweep: could not remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
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
                let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
                for entry in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [] {
                    let relative = prefix.isEmpty ? entry.lastPathComponent : prefix + "/" + entry.lastPathComponent
                    if kept.contains(relative) { continue }
                    let values = try? entry.resourceValues(forKeys: Set(keys))
                    let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
                    if isFolder, ancestors.contains(relative) {
                        walk(entry, relative)
                    } else {
                        remove(entry)
                    }
                }
            }
            walk(directory(for: model), "")
        }

        for url in removed { log.notice("sweep: removed \(url.path, privacy: .public)") }
        return removed
    }

    /// Whether the model's home, or any folder between `root` and it, is a symbolic link, read
    /// with `lstat` so the link itself is what is judged. A home behind a link is somewhere
    /// else's folder: the sweep never enters it and leaves the link where it is.
    func reachedThroughLink(_ model: ModelManifest.Model) -> Bool {
        let home = Self.components(directory(for: model))
        let depth = Self.components(root).count
        guard home.count > depth else { return true }
        var url = root
        for name in home[depth...] {
            url = url.appendingPathComponent(name)
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }
}

/// The Neural Engine's compiled bundles for the models, which CoreML writes under the app's
/// Caches on the first load after every install and never takes away: one generation per install
/// until iOS purges Caches under pressure. Cleared as a whole, and only on a new install, before
/// any model loads (`ModelHousekeeping.launch`), so the next load compiles the one generation this
/// install uses. Nothing else in Caches is touched.
struct CompileCache {
    /// The install the cache was last cleared for.
    static let recorded = "topo.models.compileCacheInstall"

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
        /// The install recorded is this one: nothing done.
        case sameInstall
        case cleared
        case absent
        /// The removal threw; nothing recorded, so the next launch tries again.
        case failed(String)
    }

    /// Clears the cache when `install` is not the one last recorded. The key is recorded only
    /// once the directory is gone or was never there.
    @discardableResult
    func clear(install: String) -> Outcome {
        if defaults.string(forKey: Self.recorded) == install { return .sameInstall }
        let outcome: Outcome
        do {
            try remove(directory)
            outcome = .cleared
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            outcome = .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            outcome = .absent
        } catch {
            log.error("compile cache: not cleared, retried next launch: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        defaults.set(install, forKey: Self.recorded)
        log.notice("compile cache: \(outcome == .cleared ? "cleared" : "absent", privacy: .public) for install \(install, privacy: .public)")
        return outcome
    }

    /// What every install changes: the `LC_UUID` of the image this code is linked into. ld writes
    /// it from a hash of the image, so any build that changes the code changes it, whatever
    /// `CFBundleVersion` says (every development install carries 1), and a relaunch of the same
    /// install never does. In a release build the image is the main executable; in a debug build
    /// Xcode links the app's code into `Topo.debug.dylib` beside a stub executable that barely
    /// changes, which is why this reads the image holding this code rather than image zero.
    static func installKey() -> String? {
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

enum ModelHousekeeping {
    /// The launch's first word on the models, in order: the compile cache is cleared for a new
    /// install, and only then are the ear and the voice made, since a debug build's may start
    /// loading as they are made. Their `prepare` runs on the foreground, from the scene's body,
    /// which SwiftUI only evaluates after the app's `init` has returned.
    @MainActor
    static func launch<Ear, Voice>(clear: () -> Void, ear: () -> Ear, voice: () -> Voice) -> (Ear, Voice) {
        clear()
        return (ear(), voice())
    }

    /// The clear as the app runs it: this install's key against the standard cache. An image
    /// whose key cannot be read clears nothing and records nothing.
    static func clearCompileCache() {
        guard let cache = CompileCache.standard(), let key = CompileCache.installKey() else {
            log.error("compile cache: no install key or bundle id; not cleared")
            return
        }
        cache.clear(install: key)
    }
}
#endif
