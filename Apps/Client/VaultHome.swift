#if os(iOS)
import Foundation
import Security

/// Where the vault folder is. Two homes: the app's own Documents, which every phone has from the
/// first launch and Files shows under On My iPhone › Topo, and a folder in iCloud Drive the person
/// picked, which Obsidian opens on the phone and iCloud Drive carries to their Macs.
///
/// The home is the bookmark: a folder picked with the document picker, kept in the keychain
/// beside the tokens because it is a capability to the person's files and not a setting. No
/// bookmark is the local home, so there is one thing to write at the move's commit point and one
/// thing to read at launch.
///
/// Nothing here asks for an entitlement. The picker's grant is the whole of the permission story:
/// the app has no iCloud Drive entitlement and none to Obsidian's container, and what it may reach
/// is exactly what the person handed it.
enum VaultHome {
    /// A picked folder the app accepts.
    enum Pick: Equatable {
        /// A vault folder inside Obsidian's own container, which is what Obsidian opens on the
        /// phone.
        case obsidianVault(String)
        /// iCloud Drive itself. Access to all of it is a thing a person may give their own mind;
        /// the vault is made at `Obsidian/<the mind's name>` under it, since Obsidian does not
        /// open a folder anywhere else in iCloud Drive.
        case iCloudDriveRoot
    }

    /// Why a picked folder is not one of those. The picker offers local storage and every
    /// installed provider beside iCloud Drive, so a pick is judged before anything is kept and
    /// before anything is copied.
    enum Refusal: Error, Equatable {
        /// Not a ubiquitous item: On My iPhone, or a provider that is not iCloud Drive.
        case notInICloudDrive
        /// In iCloud Drive, and not a folder Obsidian opens.
        case notAVaultFolder
        /// This app's own home does not have the shape the ubiquity root is read from, so there
        /// is nothing to judge a path against. Not a state a phone reaches; a refusal rather than
        /// a guess.
        case unknownLayout

        var reason: String {
            switch self {
            case .notInICloudDrive:
                "that folder is not in iCloud Drive, so nothing outside this phone would see it"
            case .notAVaultFolder:
                "that folder is in iCloud Drive, but Obsidian opens a vault only inside its own "
                    + "folder: pick one in iCloud Drive › Obsidian, or iCloud Drive itself"
            case .unknownLayout:
                "this app cannot tell where iCloud Drive is on this device"
            }
        }
    }

    /// The folder every ubiquity container sits in, under the user's own Library.
    static let ubiquityDirectory = "Mobile Documents"
    /// iCloud Drive's own container.
    static let cloudDocsContainer = "com~apple~CloudDocs"
    /// Obsidian's container. Its vaults are the folders one level under its `Documents`.
    static let obsidianContainer = "iCloud~md~obsidian"
    /// What the vault is called when the person picks iCloud Drive itself and the app makes the
    /// folder. The mind has one name today and this is it; when a person names their own, that
    /// name is what this reads.
    static let vaultName = "Topo"
    /// The folder Obsidian's vaults are made in, from iCloud Drive's root.
    static let obsidianFolderName = "Obsidian"

    /// The one ubiquity root on this device: `<user>/Library/Mobile Documents`, read off this
    /// app's own home, which is `<user>/Containers/Data/Application/<uuid>`. Nil when the home
    /// does not have that shape, which is every platform that is not this one.
    ///
    /// It is a root and not a name. A folder called `Mobile Documents` that the person made
    /// inside iCloud Drive is an ordinary folder of theirs, and matching on the name alone would
    /// read the containers under it as real ones.
    static func ubiquityRoot(home: String = NSHomeDirectory()) -> URL? {
        let components = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        guard let containers = components.firstIndex(of: "Containers"), containers > 0 else { return nil }
        var url = URL(fileURLWithPath: "/")
        for component in components[1..<containers] { url.append(path: component) }
        return url.appending(path: "Library/\(ubiquityDirectory)", directoryHint: .isDirectory)
    }

    /// Where the picker opens: Obsidian's vaults folder. The app has no access to that path and
    /// cannot check it — a sandboxed `fileExists` there is false whether or not Obsidian is
    /// installed — so it is handed over as a hint and the picker falls back to its own default
    /// when it is wrong.
    static func obsidianDirectory(home: String = NSHomeDirectory()) -> URL? {
        ubiquityRoot(home: home)?
            .appending(path: "\(obsidianContainer)/Documents", directoryHint: .isDirectory)
    }

    /// Judges a picked folder.
    ///
    /// `isUbiquitous` is the seam a test stands in for, since a simulator has no iCloud Drive and
    /// a URL's own answer there is always no; on the phone it is the URL's `isUbiquitousItemKey`,
    /// read with access to the picked URL started. `ubiquityRoot` is the other: a test's folders
    /// are under its own temporary directory and not under this device's Library.
    static func judge(_ url: URL, ubiquityRoot root: URL? = VaultHome.ubiquityRoot(),
                      isUbiquitous: (URL) -> Bool = VaultHome.isUbiquitous) -> Result<Pick, Refusal> {
        guard isUbiquitous(url) else { return .failure(.notInICloudDrive) }
        guard let root else { return .failure(.unknownLayout) }
        guard let rest = components(of: url, under: root) else { return .failure(.notAVaultFolder) }
        guard let container = rest.first else { return .failure(.notAVaultFolder) }
        let inside = Array(rest.dropFirst())
        if container == cloudDocsContainer, inside.isEmpty { return .success(.iCloudDriveRoot) }
        if container == obsidianContainer, inside.count == 2, inside[0] == "Documents" {
            return .success(.obsidianVault(inside[1]))
        }
        return .failure(.notAVaultFolder)
    }

    /// The path components of `url` below `root`, or nil when it is not under it at all. Both are
    /// compared with their links resolved as well as as written, because the picker and this
    /// app's own home can name the same folder two ways — `/private/var` for `/var` — and that is
    /// not a folder anybody moved.
    private static func components(of url: URL, under root: URL) -> [String]? {
        func below(_ inside: URL, _ outside: URL) -> [String]? {
            let a = plainPath(inside), b = plainPath(outside)
            guard a.hasPrefix(b + "/") else { return nil }
            return String(a.dropFirst(b.count + 1)).split(separator: "/").map(String.init)
        }
        if let plain = below(url, root) { return plain }
        return below(url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }

    private static func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The folder the vault lives in, for a pick. A vault folder is itself; iCloud Drive's root
    /// is where `Obsidian/<the mind's name>` is made, since a folder anywhere else in iCloud Drive
    /// is one Obsidian does not open.
    static func folder(for pick: Pick, picked: URL) -> URL {
        switch pick {
        case .obsidianVault:
            picked
        case .iCloudDriveRoot:
            picked.appending(path: obsidianFolderName, directoryHint: .isDirectory)
                .appending(path: vaultName, directoryHint: .isDirectory)
        }
    }

    /// How the settings row and the diagnostics row name a home.
    static func describe(_ url: URL, ubiquityRoot root: URL? = VaultHome.ubiquityRoot()) -> String {
        guard let root, let rest = components(of: url, under: root), let container = rest.first else {
            return url.path(percentEncoded: false)
        }
        let inside = Array(rest.dropFirst())
        if container == obsidianContainer, inside.first == "Documents" {
            return (["iCloud Drive", obsidianFolderName] + inside.dropFirst()).joined(separator: " › ")
        }
        if container == cloudDocsContainer {
            return (["iCloud Drive"] + inside).joined(separator: " › ")
        }
        return url.path(percentEncoded: false)
    }

    // MARK: The bookmark

    struct Resolved {
        var url: URL
        var stale: Bool
    }

    static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return Resolved(url: url, stale: stale)
    }

    /// A bookmark made again from the URL a stale one resolved to, which keeps the grant across
    /// whatever moved the folder. Made with access started, which is what makes it carry one.
    static func remake(_ url: URL) throws -> Data {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The phone's own answer to whether a URL is in iCloud Drive.
    static let isUbiquitous: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }
}

/// Where the home's bookmark is kept. Beside the tokens, in the keychain, because a bookmark is a
/// capability to the person's files rather than a setting: something that carries a grant is not a
/// thing to leave in defaults, which every backup and every `plist` reader can see.
protocol VaultBookmarkStore: Sendable {
    func load() throws -> Data?
    func save(_ bookmark: Data) throws
    func clear() throws
}

/// The device keychain: one generic-password item, never synced to iCloud, which is right for a
/// bookmark because a bookmark is this device's own handle and means nothing on another.
struct KeychainBookmarkStore: VaultBookmarkStore {
    var service = "zone.hexagon.topo.vault"
    var account = "home"

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
    /// What a save should do instead of keeping the bookmark, for the test of a commit that
    /// fails: the home has not moved, so the files stay where they were.
    var refuseSave: (any Swift.Error)?

    init(_ bookmark: Data? = nil) { self.bookmark = bookmark }

    func load() throws -> Data? { lock.withLock { bookmark } }
    func save(_ bookmark: Data) throws {
        if let refuseSave { throw refuseSave }
        lock.withLock { self.bookmark = bookmark }
    }
    func clear() throws { lock.withLock { bookmark = nil } }
}
#endif
