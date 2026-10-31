import Foundation
import Security

/// One generic-password item in the device keychain, as bytes: this device only
/// (`AfterFirstUnlockThisDeviceOnly`), so never synced to iCloud or restored to another phone.
public struct KeychainItem: Sendable {
    public var service: String
    public var account: String

    #if os(macOS)
    /// A file-based keychain to hold the item in, instead of the default search list. Nil, which
    /// is what the apps use, leaves every query as it is on iOS. The keychain tests set it to a
    /// keychain the test creates and unlocks, so the round trip neither needs an unlocked login
    /// keychain nor writes to it. A path that does not open is an error, never a fall back to the
    /// default keychain.
    public var keychainPath: String?
    #endif

    public init(service: String, account: String) {
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

    public func read() throws -> Data? {
        var q = try query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Error(status: status) }
        return data
    }

    public func write(_ data: Data) throws {
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

    public func delete() throws {
        _ = try deleteIfPresent()
    }

    /// Deletes the item, answering whether there was one.
    public func deleteIfPresent() throws -> Bool {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error(status: status) }
        return status == errSecSuccess
    }
}
