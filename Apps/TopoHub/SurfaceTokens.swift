import Foundation
import TopoAuth
import TopoLink

/// Where the hub keeps its surface tokens: the keychain, because a token is
/// a credential. The rules about minting and revoking are `SurfaceTokens`
/// itself, and what a store that cannot be read or written does is
/// `SurfaceTokenKeeper`, both in `TopoLink`, where they are tested.
extension SurfaceTokenKeeper {
    static func keychain() -> SurfaceTokenKeeper {
        let item = KeychainItem(service: HubIdentity.service, account: "surface-tokens")
        return SurfaceTokenKeeper(read: { try item.read() }, write: { try item.write($0) })
    }
}
