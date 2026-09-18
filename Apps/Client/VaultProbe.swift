#if DEBUG && os(iOS)
import Foundation
import Observation
import Security

/// The probe behind "Probe iCloud Drive…" in the chat menu: a folder the person picks with the
/// document picker, kept as a security-scoped bookmark, and the three things the vault's other
/// home would need of it — resolve it after a relaunch, read a file out of it, write a file into
/// it. Nothing here touches the vault or the mirror; `Memory` does not read it and does not know
/// it exists.
///
/// It answers one question, which is the reason the `.iCloudDrive` home is not built yet: whether
/// a folder in iCloud Drive › Obsidian, granted by the picker alone and with no entitlement of
/// ours to iCloud Drive or to Obsidian's container, is a folder this app can still read and write
/// on a later launch — including a file iCloud Drive has evicted, which is a download to ask for
/// and wait on rather than bytes to read.
///
/// Debug builds only. What it learns is a device test's answer, not a feature.
@MainActor
@Observable
final class VaultProbe {
    /// Where the probe stands, as the screen says it.
    enum State: Equatable {
        /// No folder has been picked, or Forget dropped the one that was.
        case none
        /// A bookmark resolved on this launch, to this path. `stale` is the bookmark asking to be
        /// re-made, which resolving it does and which the screen still says, since a bookmark that
        /// is stale on every launch is a finding.
        case home(path: String, stale: Bool)
        /// A bookmark is kept and did not resolve: the folder gone, iCloud Drive off, the grant
        /// no longer honoured. Which of those it is, is what the reason says.
        case lost(String)
    }

    private(set) var state: State = .none
    /// What the last Read, Write or pick did, shown under the home. One line per step, so a
    /// device test reads the order as well as the outcome.
    private(set) var report: [String] = []
    private(set) var busy = false

    private let store: any VaultBookmarkStore
    private let now: @Sendable () -> Date
    /// The bookmark as it stands in the store, held here so an operation does not read the
    /// keychain again per step.
    private var bookmark: Data?

    init(store: any VaultBookmarkStore = KeychainBookmarkStore(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    // MARK: - What a pick may be

    /// A picked folder this probe accepts.
    enum Pick: Equatable {
        /// A vault folder inside Obsidian's own container, which is what Obsidian opens on the
        /// phone and what iCloud Drive carries to the person's Macs.
        case obsidianVault(String)
        /// iCloud Drive itself. Access to all of it is a thing a person may give their own mind,
        /// and the folder to make under it is the move's question, not the probe's.
        case iCloudDriveRoot
    }

    /// Why a picked folder is not one of those. The picker offers local storage and third-party
    /// providers beside iCloud Drive, so a pick is judged before anything is kept.
    enum Refusal: Error, Equatable {
        /// Not a ubiquitous item: On My iPhone, or a provider that is not iCloud Drive.
        case notInICloudDrive
        /// In iCloud Drive, and not a folder Obsidian opens.
        case notAVaultFolder

        var reason: String {
            switch self {
            case .notInICloudDrive:
                "that folder is not in iCloud Drive, so nothing outside this phone would see it"
            case .notAVaultFolder:
                "that folder is in iCloud Drive, but Obsidian opens a vault only inside its own "
                    + "folder: pick one in iCloud Drive › Obsidian, or iCloud Drive itself"
            }
        }
    }

    /// The container every iCloud Drive path is under, as a path component.
    static let ubiquityDirectory = "Mobile Documents"
    /// iCloud Drive's own container.
    static let cloudDocsContainer = "com~apple~CloudDocs"
    /// Obsidian's container. Its vaults are the folders one level under its `Documents`.
    static let obsidianContainer = "iCloud~md~obsidian"

    /// Judges a picked folder. `isUbiquitous` is the seam a test stands in for, since a simulator
    /// has no iCloud Drive and a URL's own answer there is always no; on the phone it is the
    /// URL's `isUbiquitousItemKey`, read with access to the picked URL started.
    static func judge(_ url: URL, isUbiquitous: (URL) -> Bool) -> Result<Pick, Refusal> {
        guard isUbiquitous(url) else { return .failure(.notInICloudDrive) }
        let components = url.standardizedFileURL.pathComponents
        guard let containerIndex = components.lastIndex(of: ubiquityDirectory).map({ $0 + 1 }),
              containerIndex < components.count else {
            return .failure(.notAVaultFolder)
        }
        let container = components[containerIndex]
        let rest = Array(components[(containerIndex + 1)...])
        if container == cloudDocsContainer, rest.isEmpty { return .success(.iCloudDriveRoot) }
        if container == obsidianContainer, rest.count == 2, rest[0] == "Documents" {
            return .success(.obsidianVault(rest[1]))
        }
        return .failure(.notAVaultFolder)
    }

    /// Where the picker opens: Obsidian's vaults folder, if this app's own container says where
    /// the user's home is. The app has no access to that path and cannot check it — a sandboxed
    /// `fileExists` there is false whether or not Obsidian is installed — so it is handed over as
    /// a hint and the picker falls back to its own default when it is wrong. Nil when the home
    /// does not have the shape read here, which is every simulator run under a different layout
    /// and every platform that is not this one.
    static func obsidianDirectory(home: String = NSHomeDirectory()) -> URL? {
        let components = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        guard let containers = components.firstIndex(of: "Containers"), containers > 0 else { return nil }
        var url = URL(fileURLWithPath: "/")
        for component in components[1..<containers] { url.append(path: component) }
        return url.appending(path: "Library/\(ubiquityDirectory)/\(obsidianContainer)/Documents",
                             directoryHint: .isDirectory)
    }

    // MARK: - The bookmark

    /// Reads the kept bookmark and says where it resolves to. Called when the screen appears, so
    /// what it says is this launch's answer and not the pick's.
    func load() {
        do {
            bookmark = try store.load()
        } catch {
            bookmark = nil
            state = .lost("the keychain refused the bookmark: \(error)")
            return
        }
        guard let bookmark else {
            state = .none
            return
        }
        resolveAndDescribe(bookmark)
    }

    /// Keeps a picked folder, once it has been judged. The bookmark is made from the picked URL
    /// with access to it started, which is what makes it a bookmark that carries the grant.
    func keep(_ url: URL, isUbiquitous: (URL) -> Bool = VaultProbe.isUbiquitous) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        report = ["picked \(url.path)", started ? "access started" : "access was not scoped"]
        switch Self.judge(url, isUbiquitous: isUbiquitous) {
        case .failure(let refusal):
            say("refused: \(refusal.reason)")
        case .success(let pick):
            switch pick {
            case .obsidianVault(let name): say("an Obsidian vault: \(name)")
            case .iCloudDriveRoot: say("iCloud Drive itself")
            }
            do {
                let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
                try store.save(data)
                bookmark = data
                say("bookmark kept, \(data.count) bytes")
                resolveAndDescribe(data)
            } catch {
                say("the bookmark was not kept: \(error)")
            }
        }
    }

    /// Drops the bookmark. The folder and everything in it stay where they are; what goes is this
    /// app's way back to them.
    func forget() {
        do {
            try store.clear()
            bookmark = nil
            state = .none
            report = ["forgotten"]
        } catch {
            report = ["the keychain refused to drop the bookmark: \(error)"]
        }
    }

    private func resolveAndDescribe(_ data: Data) {
        do {
            let resolved = try Self.resolve(data)
            state = .home(path: resolved.url.path, stale: resolved.stale)
            if resolved.stale {
                // A stale bookmark still resolves; what it asks for is to be made again from the
                // URL it resolved to, which keeps the grant across the move that staled it.
                do {
                    let fresh = try Self.remake(resolved.url)
                    try store.save(fresh)
                    bookmark = fresh
                    say("the bookmark was stale and was made again")
                } catch {
                    say("the bookmark is stale and could not be made again: \(error)")
                }
            }
        } catch {
            state = .lost("\(error)")
        }
    }

    // MARK: - Reading and writing

    /// Lists the folder and reads one file out of it, asking iCloud Drive for the file first when
    /// it is not downloaded and waiting, with a bound, before the read. `named` empty reads the
    /// first file the listing offers.
    func read(named name: String) async {
        await run { bookmark in await Self.read(bookmark: bookmark, named: name) }
    }

    /// Writes `topo-probe.md` into the folder, through a coordinated write, with the time on it.
    func write() async {
        let stamp = now().formatted(date: .abbreviated, time: .standard)
        await run { bookmark in await Self.write(bookmark: bookmark, stamp: stamp) }
    }

    private func run(_ body: @escaping @Sendable (Data) async -> [String]) async {
        guard let bookmark else {
            report = ["no folder has been picked"]
            return
        }
        guard !busy else { return }
        busy = true
        report = []
        let lines = await body(bookmark)
        busy = false
        report = lines
    }

    private func say(_ line: String) { report.append(line) }

    // MARK: - Off the main actor

    /// How long a file iCloud Drive has evicted is waited for before the read is called
    /// incomplete. A bound, because a wait with no end is a screen that never answers.
    nonisolated static let downloadTimeout: Duration = .seconds(30)

    struct Resolved {
        var url: URL
        var stale: Bool
    }

    nonisolated static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return Resolved(url: url, stale: stale)
    }

    nonisolated static func remake(_ url: URL) throws -> Data {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The phone's own answer to whether a URL is in iCloud Drive.
    nonisolated static let isUbiquitous: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    private nonisolated static func read(bookmark: Data, named name: String) async -> [String] {
        var lines: [String] = []
        do {
            let resolved = try resolve(bookmark)
            lines.append("resolved \(resolved.url.path)\(resolved.stale ? " (stale)" : "")")
            // Every access is started and stopped on the bookmark's own URL, never on a child of
            // it: the grant is to the folder, and a child URL made by appending carries none.
            guard resolved.url.startAccessingSecurityScopedResource() else {
                return lines + ["access was refused"]
            }
            defer { resolved.url.stopAccessingSecurityScopedResource() }
            let names = try await coordinated(resolved.url, reading: true) { url in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])
                    .map(\.lastPathComponent)
                    .sorted()
            }
            lines.append("listed \(names.count): \(names.prefix(20).joined(separator: ", "))")
            guard let target = name.isEmpty ? names.first : name else {
                return lines + ["nothing to read"]
            }
            guard names.contains(target) else { return lines + ["\(target) is not in the folder"] }
            let file = resolved.url.appending(path: target)
            lines.append(contentsOf: await download(file))
            let bytes = try await coordinated(file, reading: true) { url in
                try Data(contentsOf: url).count
            }
            lines.append("read \(target): \(bytes) bytes")
        } catch {
            lines.append("failed: \(error)")
        }
        return lines
    }

    private nonisolated static func write(bookmark: Data, stamp: String) async -> [String] {
        var lines: [String] = []
        do {
            let resolved = try resolve(bookmark)
            lines.append("resolved \(resolved.url.path)\(resolved.stale ? " (stale)" : "")")
            guard resolved.url.startAccessingSecurityScopedResource() else {
                return lines + ["access was refused"]
            }
            defer { resolved.url.stopAccessingSecurityScopedResource() }
            let file = resolved.url.appending(path: "topo-probe.md")
            let text = "# Topo probe\n\nWritten \(stamp).\n"
            try await coordinated(file, reading: false) { url in
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            lines.append("wrote topo-probe.md, \(text.utf8.count) bytes")
        } catch {
            lines.append("failed: \(error)")
        }
        return lines
    }

    /// Asks iCloud Drive for a file that is not on this device and waits for it, up to the bound.
    /// A file that is already current costs one look and no wait.
    private nonisolated static func download(_ file: URL) async -> [String] {
        func status(_ url: URL) -> URLUbiquitousItemDownloadingStatus? {
            try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
        }
        let before = status(file)
        guard before != .current else { return ["already downloaded"] }
        var lines = ["not downloaded (\(before?.rawValue ?? "no status")); asking iCloud Drive"]
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
        } catch {
            return lines + ["the download was refused: \(error)"]
        }
        let deadline = ContinuousClock.now + downloadTimeout
        while ContinuousClock.now < deadline {
            if status(file) == .current { return lines + ["downloaded"] }
            try? await Task.sleep(for: .milliseconds(250))
        }
        lines.append("still not downloaded after \(downloadTimeout); reading anyway")
        return lines
    }

    /// `NSFileCoordinator.coordinate` blocks the thread it is called on until every other
    /// accessor has let go, and the threads a Swift task runs on are a handful the whole process
    /// shares, so the wait is spent on a queue of this probe's own and the caller is suspended
    /// for it. The same reason `VaultMirror` has one; this is not that one, because the probe
    /// touches no folder the mirror does.
    private nonisolated static let coordinating = DispatchQueue(label: "zone.hexagon.topo.vault-probe",
                                                                qos: .userInitiated, attributes: .concurrent)

    private nonisolated static func coordinated<T: Sendable>(
        _ url: URL, reading: Bool, body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            coordinating.async {
                continuation.resume(with: Result {
                    var outcome: Result<T, any Error>?
                    var failure: NSError?
                    let coordinator = NSFileCoordinator()
                    let accessor: (URL) -> Void = { url in outcome = Result { try body(url) } }
                    if reading {
                        coordinator.coordinate(readingItemAt: url, options: [], error: &failure, byAccessor: accessor)
                    } else {
                        coordinator.coordinate(writingItemAt: url, options: [], error: &failure, byAccessor: accessor)
                    }
                    if let failure { throw failure }
                    guard let outcome else { throw CocoaError(.fileReadUnknown) }
                    return try outcome.get()
                })
            }
        }
    }
}

/// Where the probe's bookmark is kept. Beside the tokens, in the keychain, because a bookmark is
/// a capability to the person's files rather than a setting: something that carries a grant is
/// not a thing to leave in defaults, which every backup and every `plist` reader can see.
protocol VaultBookmarkStore: Sendable {
    func load() throws -> Data?
    func save(_ bookmark: Data) throws
    func clear() throws
}

/// The device keychain: one generic-password item, never synced to iCloud, which is right for a
/// bookmark because a bookmark is this device's own handle and means nothing on another.
struct KeychainBookmarkStore: VaultBookmarkStore {
    var service = "zone.hexagon.topo.vault"
    var account = "probe"

    struct Error: Swift.Error, Equatable {
        var status: OSStatus
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Error(status: status) }
        return data
    }

    func save(_ bookmark: Data) throws {
        let update: [String: Any] = [kSecValueData as String: bookmark]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = bookmark
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error(status: status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
    }
}

/// For the tests, which have no keychain to write to and nothing to keep.
final class InMemoryBookmarkStore: VaultBookmarkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bookmark: Data?

    init(_ bookmark: Data? = nil) { self.bookmark = bookmark }

    func load() throws -> Data? { lock.withLock { bookmark } }
    func save(_ bookmark: Data) throws { lock.withLock { self.bookmark = bookmark } }
    func clear() throws { lock.withLock { bookmark = nil } }
}
#endif
