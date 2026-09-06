import Foundation
import TopoCore
import TopoLink

/// Where the hub keeps its surface tokens: the keychain, because a token is
/// a credential. The rules about minting and revoking are `SurfaceTokens`
/// itself, in `TopoLink`, where they are tested.
extension SurfaceTokens {
    private static let service = HubIdentity.service
    private static let account = "surface-tokens"

    static func load() -> SurfaceTokens {
        guard let data = KeychainItem.read(service: service, account: account),
              let stored = try? JSONDecoder().decode(SurfaceTokens.self, from: data) else {
            return SurfaceTokens()
        }
        return stored
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainItem.write(service: Self.service, account: Self.account, data: data)
    }
}
