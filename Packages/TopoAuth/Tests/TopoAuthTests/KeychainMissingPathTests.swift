#if os(macOS)
import Foundation
import Security
import Testing
import TopoAuth

/// A keychain path with no keychain file at it is a refusal the caller can tell apart
/// (`errSecNoSuchKeychain`), never a read of nothing that `readOrMake` would answer by making a
/// value and adding it somewhere else. `SecKeychainOpen` itself succeeds on a missing file.
@Suite struct KeychainMissingPathTests {
    private struct Made: Error {}

    private func item(at path: String) -> KeychainItem {
        var item = KeychainItem(service: "zone.hexagon.topo.tests", account: "missing-path")
        item.keychainPath = path
        return item
    }

    @Test func aPathNoKeychainWasEverMadeAtIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topo-keychain-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("absent.keychain-db").path
        let item = item(at: path)
        let read = #expect(throws: KeychainItem.Error.self) { try item.read() }
        #expect(read?.status == errSecNoSuchKeychain)
        var made = 0
        // `make` throws, so a store that takes the path for no item stops at it and writes nothing.
        let readOrMake = #expect(throws: KeychainItem.Error.self) { try item.readOrMake { made += 1; throw Made() } }
        #expect(readOrMake?.status == errSecNoSuchKeychain)
        #expect(made == 0, "a value was made for a keychain that is not there")
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
#endif
