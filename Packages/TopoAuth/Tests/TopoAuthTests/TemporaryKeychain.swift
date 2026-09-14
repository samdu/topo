#if os(macOS)
import Foundation
import Security
import Testing

/// A file-based keychain of the test's own, in a temporary directory, for `KeychainTokenStoreTests`.
/// It is never added to the search list or made the default, so nothing outside the test sees it.
/// The legacy keychain calls are deprecated; they are the only way to make a keychain that is not the
/// user's, and they are used only here.
struct TemporaryKeychain {
    let directory: URL
    let path: String
    let keychain: SecKeychain

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topo-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("tests.keychain-db").path
        let password = Array((UUID().uuidString + UUID().uuidString).utf8)
        var ready = false
        var created: SecKeychain?
        defer {
            if !ready {
                if let created { SecKeychainDelete(created) }
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let status = SecKeychainCreate(path, UInt32(password.count), password, false, nil, &created)
        try #require(status == errSecSuccess, "SecKeychainCreate at \(path) failed: \(status)")
        let keychain = try #require(created)

        // A keychain made outside a login session comes back locked, and its settings cannot be
        // changed until it is unlocked.
        let unlock = SecKeychainUnlock(keychain, UInt32(password.count), password, true)
        try #require(unlock == errSecSuccess, "SecKeychainUnlock failed: \(unlock)")
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                           lockOnSleep: false, useLockInterval: false, lockInterval: UInt32(Int32.max))
        let set = SecKeychainSetSettings(keychain, &settings)
        try #require(set == errSecSuccess, "SecKeychainSetSettings failed: \(set)")
        var state: SecKeychainStatus = 0
        let got = SecKeychainGetStatus(keychain, &state)
        try #require(got == errSecSuccess && state & SecKeychainStatus(kSecUnlockStateStatus) != 0,
                     "keychain at \(path) is not unlocked: status \(got), state \(state)")

        ready = true
        self.directory = directory
        self.path = path
        self.keychain = keychain
    }

    /// Whether this keychain, and only this one, holds a generic password under `service` and
    /// `account`: how the test sees that the store wrote where it was pointed.
    func holdsItem(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [keychain],
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
