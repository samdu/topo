#if canImport(CloudKit)
import Foundation
import Testing
@testable import TopoCore

/// A zone's copy on disk is kept under the environment that answered it, and the environment is
/// read from what a build is signed with.
@Suite struct CloudEnvironmentTests {
    private let account = Data("account".utf8)

    private func caches() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("caches-\(UUID().uuidString)", isDirectory: true)
    }

    /// A feed that answers one page from any token, and records the tokens it was asked from.
    private actor Server {
        let name: String
        private(set) var asked: [Data?] = []
        init(_ name: String) { self.name = name }
        func page(since token: Data?) -> ZoneFeedPage {
            asked.append(token)
            return ZoneFeedPage(changed: [Record(type: "Turn", id: RecordID("\(name)-turn"), fields: [:])], deleted: [],
                                token: Data("\(name)-token".utf8), moreComing: false)
        }
    }

    private func read(_ server: Server, _ store: ZoneMirror.Store) async throws -> [String] {
        try await ZoneMirror(store: store) { try await server.page(since: $0) }.records(ofType: "Turn").map(\.id.name)
    }

    @Test func aCopyReadFromDevelopmentIsNeverOfferedToProduction() async throws {
        let caches = caches()
        let development = Server("development"), production = Server("production")
        let key = "2/_defaultOwner/Topo"
        _ = try await read(development, CloudKitRecordDatabase.store(named: key, account: account, environment: .development, caches: caches))
        let read = try await read(production, CloudKitRecordDatabase.store(named: key, account: account, environment: .production, caches: caches))
        #expect(await production.asked == [nil])
        #expect(read == ["production-turn"])
        // And back: the copy production kept is not offered to development either.
        _ = try await self.read(development, CloudKitRecordDatabase.store(named: key, account: account, environment: .development, caches: caches))
        #expect(await development.asked == [nil, nil])
    }

    @Test func aCopyKeptUnderTheAccountAloneIsAWalkFromTheBeginning() async throws {
        let caches = caches()
        let key = "2/_defaultOwner/Topo"
        let current = CloudKitRecordDatabase.store(named: key, account: account, environment: .production, caches: caches)
        // A copy as a build keyed by the account alone kept it, at the same file.
        _ = try await read(Server("development"), ZoneMirror.Store(file: current.file, owner: account))
        let production = Server("production")
        #expect(try await read(production, current) == ["production-turn"])
        #expect(await production.asked == [nil])
    }

    // MARK: - Read from the signing

    private func profile(_ entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "Topo", "Entitlements": entitlements],
                                                       format: .xml, options: 0)
        // The plist sits inside a CMS envelope, with signed bytes either side of it.
        return Data([0x30, 0x80, 0x06, 0x09]) + plist + Data([0xA0, 0x82, 0x0B, 0x00])
    }

    @Test func aDevelopmentProfileIsDevelopment() throws {
        let data = try profile(["get-task-allow": true, "aps-environment": "development",
                                "com.apple.developer.icloud-container-environment": ["Production", "Development"]])
        #expect(CloudEnvironment(profile: data, present: true) == .development)
    }

    @Test func aDistributionProfileIsProduction() throws {
        let data = try profile(["get-task-allow": false, "aps-environment": "production", "beta-reports-active": true,
                                "com.apple.developer.icloud-container-environment": ["Production", "Development"]])
        #expect(CloudEnvironment(profile: data, present: true) == .production)
    }

    @Test func noProfileIsProduction() {
        #expect(CloudEnvironment(profile: Data(), present: false) == .production)
    }

    @Test func aProfileThatCannotBeReadIsNoEnvironment() throws {
        #expect(CloudEnvironment(profile: Data("not a profile".utf8), present: true) == nil)
        #expect(CloudEnvironment(profile: Data(), present: true) == nil)
    }

    @Test func aSignedEnvironmentIsTakenAsItIs() {
        #expect(CloudEnvironment(entitlements: ["com.apple.developer.icloud-container-environment": "Production",
                                                "get-task-allow": true]) == .production)
        #expect(CloudEnvironment(entitlements: ["com.apple.developer.icloud-container-environment": "Development"]) == .development)
        #expect(CloudEnvironment(entitlements: ["com.apple.security.get-task-allow": true]) == .development)
        #expect(CloudEnvironment(entitlements: [:]) == .production)
    }
}
#endif
