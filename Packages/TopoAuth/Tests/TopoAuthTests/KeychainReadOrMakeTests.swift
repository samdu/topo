#if os(macOS)
import Foundation
import Testing
import TopoAuth

/// `readOrMake` makes a value only where there is none, and reads it after.
@Suite struct KeychainReadOrMakeTests {
    @Test func aValueIsMadeOnceAndReadAfter() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        var item = KeychainItem(service: "zone.hexagon.topo.tests", account: "read-or-make")
        item.keychainPath = keychain.path
        var made = 0
        let first = try item.readOrMake { made += 1; return Data("first".utf8) }
        let second = try item.readOrMake { made += 1; return Data("second".utf8) }
        #expect(first == Data("first".utf8))
        #expect(second == first)
        #expect(made == 1)
    }
}
#endif
