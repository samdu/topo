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
    /// Where a deliberate takeover is, in words, while it runs. Nil otherwise.
    private(set) var taking: String?

    private let database: any RecordDatabase
    private let device: DeviceID
    private let defaults: UserDefaults
    private let isSignedIn: @Sendable () -> Bool
    private let ensureZone: @Sendable () async throws -> Void
    private let timing: LeaseTiming
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private static let key = "topo.role"

    /// - Parameter ensureZone: run before the first claim, because the lease record goes in the
    ///   zone the writers create. Injected so a test can hold a database and no iCloud.
    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         defaults: UserDefaults = .standard, isSignedIn: @escaping @Sendable () -> Bool,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         timing: LeaseTiming = .standard,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.database = database
        self.device = device
        self.defaults = defaults
        self.isSignedIn = isSignedIn
        self.ensureZone = ensureZone
        self.timing = timing
        self.sleep = sleep
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
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NeverConfirms(), timing: timing)
        return try await lease.claimIfNone()
    }

    /// The deliberate takeover, from the settings of a viewer: this device becomes primary and
    /// the device that was stops answering. The one control that hands primary over, for a
    /// primary phone that is lost, wiped or simply retired.
    ///
    /// The safety is the wait: a lease that is fresh is left to lapse, one duration at most,
    /// before the claim, so a holder that is merely between heartbeats keeps its lease if it
    /// heartbeats again, and only a holder that has stopped is claimed over; a holder that keeps
    /// heartbeating through the wait is alive and is claimed over anyway, and yields on its next
    /// heartbeat, as the lease provides. On success the role is primary, the screen shows
    /// sign-in, and the lease instance that made the claim is returned for the harness to keep:
    /// the displaced device yields to that lease's epoch, and a second claim from another
    /// instance would be an epoch it never yielded to, which it would claim back over. On failure
    /// nil, the role unchanged, and `trouble` says why.
    @discardableResult
    func takePrimary() async -> PrimaryLease? {
        guard taking == nil else { return nil }
        defer { taking = nil }
        do {
            taking = "Checking who is primary…"
            let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NeverConfirms(), timing: timing)
            if let record = try await database.fetch(Lease.recordID), let current = Lease(record: record),
               current.holder != device, !current.isExpired(at: Date()) {
                let wait = min(current.expiresAt.timeIntervalSinceNow, timing.duration)
                taking = "Waiting \(Int(wait.rounded(.up))) seconds for \(current.holder.rawValue) to finish…"
                try await sleep(max(wait, 0))
            }
            taking = "Taking over…"
            try await ensureZone()
            switch try await lease.acquire() {
            case .primary:
                keep(.primary)
                return lease
            case .held(let by):
                trouble = "\(by.holder.rawValue) is answering right now and kept primary."
            case .unreachable(let other):
                trouble = "\(other.holder.rawValue) took primary just now. Try again in a moment."
            case .contended:
                trouble = "Another device is claiming primary. Try again in a moment."
            }
        } catch {
            trouble = TranscriptStore.message(for: error)
        }
        return nil
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
