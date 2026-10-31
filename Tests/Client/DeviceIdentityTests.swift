import Foundation
import TopoCore
import XCTest

@testable import Topo

final class DeviceIdentityTests: XCTestCase {
    private final class FakeKeychain: DeviceIdentity.Keychain {
        var held: Data?
        var unreadable = false
        var refusesWrites = false
        var writes = 0

        func read() throws -> Data? {
            if unreadable { throw NSError(domain: "keychain", code: -25308) }
            return held
        }

        func write(_ data: Data) throws {
            writes += 1
            if refusesWrites { throw NSError(domain: "keychain", code: -25308) }
            held = data
        }

        var name: String? { held.flatMap { String(data: $0, encoding: .utf8) } }
    }

    private func defaults() -> UserDefaults {
        let name = "topo.tests.identity.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private var minted = 0
    private func mint() -> String { minted += 1; return "ios-minted\(minted)" }

    func testTheKeychainsNameWinsAndIsCopiedIntoDefaults() {
        let keychain = FakeKeychain()
        keychain.held = Data("ios-kept".utf8)
        let defaults = defaults()
        defaults.set("ios-other", forKey: DeviceIdentity.key)
        let resolved = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        XCTAssertEqual(resolved, .init(id: DeviceID("ios-kept"), kept: true))
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.key), "ios-kept")
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(minted, 0)
    }

    /// A reinstall: the defaults are gone and the keychain kept the name.
    func testAReinstallFindsItsNameInTheKeychain() {
        let keychain = FakeKeychain()
        keychain.held = Data("ios-kept".utf8)
        let defaults = defaults()
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint).id, DeviceID("ios-kept"))
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.key), "ios-kept")
        XCTAssertEqual(minted, 0)
    }

    /// Every phone installed before the keychain kept the name: carried there once.
    func testANameInDefaultsAloneIsCarriedIntoTheKeychain() {
        let keychain = FakeKeychain()
        let defaults = defaults()
        defaults.set("ios-old", forKey: DeviceIdentity.key)
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint),
                       .init(id: DeviceID("ios-old"), kept: true))
        XCTAssertEqual(keychain.name, "ios-old")
        XCTAssertEqual(minted, 0)
    }

    func testWithNeitherOneNameIsMintedAndWrittenToBoth() {
        let keychain = FakeKeychain()
        let defaults = defaults()
        let resolved = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        XCTAssertEqual(resolved, .init(id: DeviceID("ios-minted1"), kept: true))
        XCTAssertEqual(minted, 1)
        XCTAssertEqual(keychain.name, "ios-minted1")
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.key), "ios-minted1")
    }

    func testASecondReadIsTheSameName() {
        let keychain = FakeKeychain()
        let defaults = defaults()
        let first = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        let second = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        XCTAssertEqual(first, second)
        // A reinstall after it, with only the keychain left, is still that name.
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: self.defaults(), mint: mint), first)
        XCTAssertEqual(minted, 1)
    }

    /// Before the first unlock: the defaults' copy is the name, and nothing is written over an
    /// item that could not be seen.
    func testAnUnreadableKeychainUsesTheDefaultsCopyAndWritesNothing() {
        let keychain = FakeKeychain()
        keychain.unreadable = true
        let defaults = defaults()
        defaults.set("ios-old", forKey: DeviceIdentity.key)
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint),
                       .init(id: DeviceID("ios-old"), kept: true))
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(minted, 0)
    }

    /// With no copy anywhere and the keychain unreadable, the launch runs under a name it keeps
    /// nowhere, so the name the keychain may hold is found by the next launch that can read it.
    func testAnUnreadableKeychainWithNoCopyMintsANameItKeepsNowhere() {
        let keychain = FakeKeychain()
        keychain.held = Data("ios-kept".utf8)
        keychain.unreadable = true
        let defaults = defaults()
        let resolved = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        XCTAssertEqual(resolved, .init(id: DeviceID("ios-minted1"), kept: false))
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertNil(defaults.string(forKey: DeviceIdentity.key))

        keychain.unreadable = false
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint).id, DeviceID("ios-kept"))
    }

    /// A refused write is left for the next launch, which carries the defaults' copy again.
    func testARefusedKeychainWriteKeepsTheDefaultsCopyAndIsCarriedNextLaunch() {
        let keychain = FakeKeychain()
        keychain.refusesWrites = true
        let defaults = defaults()
        let first = DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint)
        XCTAssertEqual(first, .init(id: DeviceID("ios-minted1"), kept: true))
        XCTAssertNil(keychain.name)
        keychain.refusesWrites = false
        XCTAssertEqual(DeviceIdentity.resolve(keychain: keychain, defaults: defaults, mint: mint), first)
        XCTAssertEqual(keychain.name, "ios-minted1")
        XCTAssertEqual(minted, 1)
    }

    func testWithNoKeychainTheDefaultsKeepTheName() {
        let defaults = defaults()
        let first = DeviceIdentity.resolve(keychain: nil, defaults: defaults, mint: mint)
        XCTAssertEqual(DeviceIdentity.resolve(keychain: nil, defaults: defaults, mint: mint), first)
        XCTAssertEqual(minted, 1)
    }
}
