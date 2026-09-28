import Foundation

/// A service Topo connects to on the person's behalf. Its token is held by the app in the device
/// keychain and never written into the guest: the guest asks the app for it over the tool service
/// each time it needs one.
public enum ConnectionService: String, CaseIterable, Sendable {
    case github
}

/// One connection: the token, and who it is on the other side, as the Connections screen says it.
public struct Connection: Codable, Equatable, Sendable {
    public var token: String
    /// The GitHub login.
    public var account: String

    public init(token: String, account: String) {
        self.token = token
        self.account = account
    }
}

/// Where the connections live: one keychain item a service, this device only.
public protocol ConnectionStore: Sendable {
    func load(_ service: ConnectionService) throws -> Connection?
    func save(_ connection: Connection, for service: ConnectionService) throws
    func clear(_ service: ConnectionService) throws
}

extension ConnectionStore {
    /// Every service's item, each attempted whatever the one before it answered; the first
    /// failure is thrown once all have been tried.
    public func clearAll() throws {
        var failure: Error?
        for service in ConnectionService.allCases {
            do { try clear(service) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}

/// The device keychain, service `zone.hexagon.topo.connections`, one account a service.
public struct KeychainConnectionStore: ConnectionStore {
    public static let service = "zone.hexagon.topo.connections"

    #if os(macOS)
    /// A file-based keychain for the tests (`KeychainItem.keychainPath`).
    public var keychainPath: String?
    #endif

    public init() {}

    private func item(_ service: ConnectionService) -> KeychainItem {
        var item = KeychainItem(service: Self.service, account: service.rawValue)
        #if os(macOS)
        item.keychainPath = keychainPath
        #endif
        return item
    }

    public func load(_ service: ConnectionService) throws -> Connection? {
        try item(service).read().map { try JSONDecoder().decode(Connection.self, from: $0) }
    }

    public func save(_ connection: Connection, for service: ConnectionService) throws {
        try item(service).write(JSONEncoder().encode(connection))
    }

    public func clear(_ service: ConnectionService) throws {
        try item(service).delete()
    }
}

/// For tests and previews.
public final class InMemoryConnectionStore: ConnectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ConnectionService: Connection]

    public init(_ connections: [ConnectionService: Connection] = [:]) { self.connections = connections }

    public func load(_ service: ConnectionService) throws -> Connection? { lock.withLock { connections[service] } }
    public func save(_ connection: Connection, for service: ConnectionService) throws {
        lock.withLock { connections[service] = connection }
    }
    public func clear(_ service: ConnectionService) throws { _ = lock.withLock { connections.removeValue(forKey: service) } }
}
