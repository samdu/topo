import CloudKit
import CryptoKit
import Foundation
import Observation
import os
import Security
import TopoCore
import TopoCoreTesting
import TopoLink

/// The hub's standing state: its own device record, the primary lease, the
/// probe listener that answers for it, and what it knows of the other
/// devices. One instance for the life of the process.
@MainActor
@Observable
final class HubModel {
    enum Status: Equatable {
        case starting
        case primary(epoch: Int64)
        case held(by: DeviceID)
        case unreachable(DeviceID)
        case contended
        case failed(String)
    }

    enum Store: String {
        case cloudKit, memory
    }

    let device: DeviceID
    let name: String
    let store: Store
    private(set) var status: Status = .starting
    private(set) var devices: [Device] = []
    private(set) var onLAN: Set<DeviceID> = []
    /// Set when the Bonjour browse cannot run, which on macOS means the app
    /// has not been allowed on the local network.
    private(set) var lanFailure: String?
    private(set) var pairingCode: PairingCode?
    private(set) var port: UInt16?

    private static let log = Logger(subsystem: "zone.hexagon.topo.hub", category: "hub")
    private let database: any RecordDatabase
    private let directory: DeviceDirectory
    private let presence = LANPresence()
    private var lease: PrimaryLease?
    private var server: LeaseProbeServer?
    private var loop: Task<Void, Never>?

    /// CloudKit when the bundle carries the iCloud entitlement, otherwise the
    /// testing package's in-memory store: an unsigned build runs, shows every
    /// screen and takes the lease against itself, and says which it is.
    init() {
        device = HubIdentity.deviceID
        name = Host.current().localizedName ?? "Mac"
        if ProcessInfo.processInfo.environment["TOPO_STORE"] != "memory", HubIdentity.hasCloudKitEntitlement {
            store = .cloudKit
            database = CloudKitRecordDatabase()
        } else {
            store = .memory
            database = InMemoryRecordDatabase()
        }
        directory = DeviceDirectory(database: database)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    /// Brings the hub up, retrying with backoff until it is, then takes the
    /// lease and keeps the device list fresh for the life of the process. A
    /// CloudKit or network outage at launch is a delay, not a verdict.
    private func run() async {
        var delay: TimeInterval = 2
        while !Task.isCancelled {
            do {
                try await bringUp()
                break
            } catch {
                Self.log.error("hub start failed, retrying in \(delay)s: \(String(describing: error), privacy: .public)")
                status = .failed("\(error)")
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
        while !Task.isCancelled {
            await acquire()
            await refreshDevices()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Ensures the zone, opens the probe listener, registers the device and
    /// makes the lease. Each step keeps what it made, so a retry after a
    /// failure picks up where it stopped.
    private func bringUp() async throws {
        if let ck = database as? CloudKitRecordDatabase { try await ck.ensureZone() }
        if server == nil {
            let server = try LeaseProbeServer(advertising: device) { [weak self] holder, epoch in
                guard let self else { return false }
                return await self.holds(holder, epoch: epoch)
            }
            port = try await server.start()
            self.server = server
            Self.log.notice("hub \(self.device.rawValue, privacy: .public) listening on \(self.port ?? 0) store \(self.store.rawValue, privacy: .public)")
        }
        let endpoints = HubIdentity.addresses().map { "\($0):\(port ?? 0)" }
        let record = try await directory.register(Device(
            id: device, name: name, kind: .mac, publicKey: HubIdentity.publicKey,
            endpoints: endpoints, registeredAt: Date(), seenAt: Date()))
        pairingCode = PairingCode(record)
        if lease == nil {
            lease = PrimaryLease(database: database, device: device, endpoint: endpoints.first,
                                 probe: SocketLeaseProbe())
            await presence.start()
            await presence.observe { [weak self] names in
                Task { @MainActor in self?.onLAN = names }
            }
        }
    }

    /// The hub takes the lease from whoever holds it and keeps it, on a
    /// timer while the hub has no turns of its own: a phone that was primary
    /// while the Mac was away is displaced and yields.
    func acquire() async {
        guard let lease else { return }
        do {
            switch try await lease.takeOver() {
            case .primary(let l): status = .primary(epoch: l.epoch)
            case .held(let by): status = .held(by: by.holder)
            case .unreachable(let l): status = .unreachable(l.holder)
            case .contended: status = .contended
            }
        } catch {
            status = .failed("\(error)")
        }
    }

    func refreshDevices() async {
        try? await directory.touch(device, at: Date())
        if let all = try? await directory.all() { devices = all }
        lanFailure = await presence.failure
    }

    private nonisolated func holds(_ holder: DeviceID, epoch: Int64) async -> Bool {
        guard let lease = await lease else { return false }
        guard await lease.isPrimary(), let held = await lease.held else { return false }
        return held.holder == holder && held.epoch == epoch
    }

    var leaseHolder: DeviceID? {
        switch status {
        case .primary: device
        case .held(let by): by
        case .unreachable(let by): by
        default: nil
        }
    }
}

/// What this Mac is to the database: a stable device ID and a key pair,
/// made once and kept in the keychain.
enum HubIdentity {
    static let service = "zone.hexagon.topo.hub"

    static var deviceID: DeviceID {
        if let existing = KeychainItem.read(service: service, account: "device"), let id = String(data: existing, encoding: .utf8) {
            return DeviceID(id)
        }
        let id = "mac-" + UUID().uuidString.lowercased()
        KeychainItem.write(service: service, account: "device", data: Data(id.utf8))
        return DeviceID(id)
    }

    static var privateKey: Curve25519.KeyAgreement.PrivateKey {
        if let raw = KeychainItem.read(service: service, account: "key"),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        KeychainItem.write(service: service, account: "key", data: key.rawRepresentation)
        return key
    }

    static var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) != nil
    }

    /// The Mac's IPv4 addresses on interfaces that are up, Wi-Fi and wired first.
    static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ifa.ifa_name)
                let address = String(cString: host)
                if name.hasPrefix("en") { out.insert(address, at: 0) } else { out.append(address) }
            }
        }
        return out
    }
}

enum KeychainItem {
    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(service: String, account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
