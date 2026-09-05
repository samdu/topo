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
/// primary whatever the record says. Until a read of the record succeeds the role is undecided
/// and nothing is claimed, so a second device never takes primary from a first it could not see.
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
    private static let key = "topo.role"

    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         defaults: UserDefaults = .standard, isSignedIn: @escaping @Sendable () -> Bool) {
        self.database = database
        self.device = device
        self.defaults = defaults
        self.isSignedIn = isSignedIn
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
            guard let record = try await database.fetch(Lease.recordID) else {
                keep(.primary)
                return
            }
            let lease = Lease(record: record)
            keep(lease?.holder == device ? .primary : .viewer)
        } catch {
            guard !TopoCloudKit.meansNoLogYet(error) else {
                keep(.primary)
                return
            }
            trouble = TranscriptStore.message(for: error)
        }
    }

    private func keep(_ role: Role) {
        self.role = role
        trouble = nil
        defaults.set(role.rawValue, forKey: Self.key)
    }
}
