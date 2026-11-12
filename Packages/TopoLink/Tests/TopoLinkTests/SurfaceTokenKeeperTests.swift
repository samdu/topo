import Foundation
import Testing
import TopoCore
import TopoLink

/// The hub's tokens as its keychain keeps them. A store that could not be read is not the same as
/// an empty one: minting into it and saving would put fresh addresses on every wall screen and
/// forget every revocation.
@Suite struct SurfaceTokenKeeperTests {
    struct Refused: Error {}

    final class Store: @unchecked Sendable {
        var data: Data?
        var readFails = false
        var writeFails = false
        var writes = 0
        /// Every write asked for, refused ones included.
        var attempts = 0
        func read() throws -> Data? {
            if readFails { throw Refused() }
            return data
        }
        func write(_ new: Data) throws {
            attempts += 1
            if writeFails { throw Refused() }
            writes += 1
            data = new
        }
    }

    let wall = DeviceID("womble-wall")
    let drawer = DeviceID("womble-drawer")

    func keeper(_ store: Store) -> SurfaceTokenKeeper {
        SurfaceTokenKeeper(read: { try store.read() }, write: { try store.write($0) })
    }

    /// A store holding one served screen and one revoked one.
    func kept() throws -> (Store, String) {
        let store = Store()
        var first = keeper(store)
        var token: String?
        first.change { tokens in
            token = tokens.mint(for: wall, named: "Wall")
            _ = tokens.mint(for: drawer, named: "Drawer")
            tokens.revoke(drawer)
        }
        return (store, try #require(token))
    }

    @Test func aStoreThatCannotBeReadIsMintedNothingAndSavedOverNever() throws {
        let (store, _) = try kept()
        let before = store.data
        store.readFails = true
        var keeper = keeper(store)
        #expect(keeper.tokens == nil)
        #expect(keeper.trouble != nil)
        let changed = keeper.change { tokens in
            _ = tokens.mint(for: wall, named: "Wall")
            _ = tokens.mint(for: drawer, named: "Drawer")
        }
        #expect(!changed)
        #expect(store.data == before, "what the keychain held is still what it holds")
    }

    /// Written never is no write asked for, not only no bytes changed: a locked keychain refuses
    /// the write as it refused the read, so a save tried over it would leave the bytes as they
    /// were and still be a save over somebody's tokens.
    @Test func aStoreThatCannotBeReadIsAskedForNoWrite() throws {
        let (store, _) = try kept()
        let before = store.attempts
        store.readFails = true
        store.writeFails = true
        var keeper = keeper(store)
        #expect(store.attempts == before, "a write was asked for at the start")
        #expect(!keeper.change { _ = $0.mint(for: wall, named: "Wall") })
        #expect(store.attempts == before, "a write was asked for by a refused change")
        keeper.reload()
        #expect(keeper.tokens == nil)
        #expect(store.attempts == before, "a write was asked for by a reload that still could not read")
    }

    @Test func onceTheStoreReadsAgainTheOldAddressesAndRevocationsAreBack() throws {
        let (store, token) = try kept()
        store.readFails = true
        var keeper = keeper(store)
        keeper.reload()
        #expect(keeper.tokens == nil)
        store.readFails = false
        keeper.reload()
        #expect(keeper.tokens?.token(for: wall) == token)
        #expect(keeper.tokens?.isRevoked(drawer) == true)
        #expect(keeper.trouble == nil)
    }

    @Test func storedBytesThatDoNotDecodeAreNotAnEmptySet() throws {
        let store = Store()
        store.data = Data("not tokens".utf8)
        var keeper = keeper(store)
        #expect(keeper.tokens == nil)
        #expect(!keeper.change { _ = $0.mint(for: wall, named: "Wall") })
        #expect(store.data == Data("not tokens".utf8))
    }

    @Test func nothingStoredIsAnEmptySet() throws {
        let store = Store()
        var keeper = keeper(store)
        #expect(keeper.tokens == SurfaceTokens())
        #expect(keeper.change { _ = $0.mint(for: wall, named: "Wall") })
        #expect(store.writes == 1)
    }

    @Test func aSaveThatFailsIsSaidAndTriedAgain() throws {
        let (store, _) = try kept()
        var keeper = keeper(store)
        store.writeFails = true
        keeper.change { $0.revoke(wall) }
        #expect(keeper.tokens?.isRevoked(wall) == true, "the revocation holds while the hub runs")
        #expect(keeper.trouble != nil)
        store.writeFails = false
        keeper.reload()
        #expect(keeper.trouble == nil)
        var next = self.keeper(store)
        next.reload()
        #expect(next.tokens?.isRevoked(wall) == true, "and is kept for the next launch")
    }
}
