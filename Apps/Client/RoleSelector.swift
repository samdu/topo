import Foundation
import Observation
import TopoCore

/// What this device is to the mind: decided once, at first launch, from the private CloudKit
/// records, and kept.
///
/// No primary exists, so become primary and show sign-in; one exists, so become a viewer and show
/// the connected-to line and the transcript. The lease record is the evidence: it exists once any
/// device has been primary, whether or not it is fresh right now (a phone in a pocket stops
/// heartbeating). A device that holds the lease itself, or already holds a Claude login, is
/// primary whatever the record says. With no record, the device stakes the first claim with a
/// create-only save, which exactly one of any number of devices launching together wins; the
/// rest become viewers. Until the record can be read the role is undecided and nothing is
/// claimed, so a second device never takes primary from a first it could not see.
@MainActor
@Observable
final class RoleSelector {
    enum Role: String, Codable {
        case primary
        case viewer
    }

    private(set) var role: Role?
    /// Why the last attempt to decide did not, in words for the screen.
    private(set) var trouble: String?

    private let database: any RecordDatabase
    private let device: DeviceID
    private let defaults: UserDefaults
    private let isSignedIn: @Sendable () -> Bool
    private let ensureZone: @Sendable () async throws -> Void
    private static let key = "topo.role"

    /// - Parameter ensureZone: run before the first claim, because the lease record goes in the
    ///   zone the writers create. Injected so a test can hold a database and no iCloud.
    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         defaults: UserDefaults = .standard, isSignedIn: @escaping @Sendable () -> Bool,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() }) {
        self.database = database
        self.device = device
        self.defaults = defaults
        self.isSignedIn = isSignedIn
        self.ensureZone = ensureZone
        if let stored = defaults.string(forKey: Self.key), let role = Role(rawValue: stored) {
            self.role = role
        }
    }

    /// Decides the role if it is not decided yet. A decision is kept; a failure to read leaves it
    /// open for the next call, with `trouble` saying why.
    func decide() async {
        guard role == nil else { return }
        if isSignedIn() {
            keep(.primary)
            return
        }
        do {
            let record: Record?
            do {
                record = try await database.fetch(Lease.recordID)
            } catch where TopoCloudKit.meansNoLogYet(error) {
                // Nothing has been written on this Apple ID yet: no zone, so no record.
                record = nil
            }
            guard let record else {
                try await ensureZone()
                keep(try await stake() ? .primary : .viewer)
                return
            }
            let lease = Lease(record: record)
            keep(lease?.holder == device ? .primary : .viewer)
        } catch {
            trouble = TranscriptStore.message(for: error)
        }
    }

    /// The first claim: true when this device created the lease record, false when another got
    /// there first.
    private func stake() async throws -> Bool {
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NeverConfirms())
        return try await lease.claimIfNone()
    }

    private struct NeverConfirms: LeaseProbe {
        func confirms(_ lease: Lease) async -> Bool { false }
    }

    private func keep(_ role: Role) {
        self.role = role
        trouble = nil
        defaults.set(role.rawValue, forKey: Self.key)
    }
}
