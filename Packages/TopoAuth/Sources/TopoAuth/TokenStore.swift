import Foundation
import Security

/// Where the Claude tokens live. Only the primary or the hub ever holds one; viewers hold nothing
/// that reaches the account.
public protocol TokenStore: Sendable {
    func load() throws -> Tokens?
    func save(_ tokens: Tokens) throws
    func clear() throws
}

/// The device keychain: one generic-password item, JSON-encoded, never synced to iCloud.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    public var account: String

    #if os(macOS)
    /// A file-based keychain to hold the item in, instead of the default search list. Nil, which
    /// is what the apps use, leaves every query as it is on iOS. `KeychainTokenStoreTests` sets it
    /// to a keychain the test creates and unlocks, so the round trip neither needs an unlocked
    /// login keychain nor writes to it. A path that does not open is an error, never a fall back
    /// to the default keychain.
    public var keychainPath: String?
    #endif

    public init(service: String = "zone.hexagon.topo.claude", account: String = "claude") {
        self.service = service
        self.account = account
    }

    public struct Error: Swift.Error, Equatable {
        public var status: OSStatus
    }

    private func query() throws -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if let keychainPath {
            var keychain: SecKeychain?
            let status = SecKeychainOpen(keychainPath, &keychain)
            guard status == errSecSuccess, let keychain else { throw Error(status: status) }
            q[kSecMatchSearchList as String] = [keychain]
        }
        #endif
        return q
    }

    public func load() throws -> Tokens? {
        var q = try query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Error(status: status) }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    public func save(_ tokens: Tokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = try query()
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #if os(macOS)
            // An add names its keychain with kSecUseKeychain; the search list is for lookups.
            if let list = add.removeValue(forKey: kSecMatchSearchList as String) as? [SecKeychain] {
                add[kSecUseKeychain as String] = list[0]
            }
            #endif
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
    }
}

/// For tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Tokens?

    public init(_ tokens: Tokens? = nil) { self.tokens = tokens }

    public func load() throws -> Tokens? { lock.withLock { tokens } }
    public func save(_ tokens: Tokens) throws { lock.withLock { self.tokens = tokens } }
    public func clear() throws { lock.withLock { tokens = nil } }
}
