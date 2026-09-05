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

    public init(service: String = "zone.hexagon.topo.claude", account: String = "claude") {
        self.service = service
        self.account = account
    }

    public struct Error: Swift.Error, Equatable {
        public var status: OSStatus
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> Tokens? {
        var q = query
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
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
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
