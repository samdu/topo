import Foundation
import Observation
import os
import TopoCore

/// What this device is to the mind: decided once, at first launch, from the private CloudKit
/// records, and kept.
///
/// No primary exists, so become primary and show sign-in; one exists, so become a viewer and show
/// the connected-to line and the transcript. The lease record is the evidence: it exists once any
/// device has been primary, whether or not it is fresh right now (a phone in a pocket stops
/// heartbeating). A device that holds the lease itself is primary. With no record, the device
/// stakes the first claim with a create-only save, which exactly one of any number of devices
/// launching together wins; the rest become viewers. Until the record can be read the role is
/// undecided and nothing is claimed, so a second device never takes primary from a first it
/// could not see.
///
/// A Claude login found at first launch is one the keychain kept across a delete of the app,
/// and so is the phone's name (`DeviceIdentity`): a reinstalled phone whose name the lease
/// names is that lease's holder, and primary. The login makes the device primary where the
/// record names no other device or cannot be read. Where the record names another device, a
/// phone, a pad or a hub, this one is a viewer, whose login the viewer screen drops: a login is
/// not what hands primary over, the viewer's menu is.
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
    private let deadline: @Sendable (TimeInterval) async throws -> Void
    /// Attempts to decide that ran out of time, which lengthen the next one's bound.
    private var ranOut = 0
    private static let key = "topo.role"

    /// - Parameter ensureZone: run before the first claim, because the lease record goes in the
    ///   zone the writers create. Injected so a test can hold a database and no iCloud.
    /// - Parameter deadline: how the first reads' bound is waited out (`firstReadBound`), apart
    ///   from `sleep`, which is the takeover's wait.
    init(database: any RecordDatabase, device: DeviceID = DeviceIdentity.current,
         defaults: UserDefaults = .standard, isSignedIn: @escaping @Sendable () -> Bool,
         ensureZone: @escaping @Sendable () async throws -> Void = { try await TopoCloudKit.ensureZone() },
         timing: LeaseTiming = .standard,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         deadline: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.deadline = deadline
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
    ///
    /// The reads it is decided from — this device's role record, the lease record and, before a
    /// first claim, the zone — are given `firstReadBound(after:)` together, and one that runs out
    /// is never taken for an answer: the role stays open, nothing is claimed, and `trouble` says
    /// iCloud has not answered, whether or not the keychain holds a login. The zone is the one
    /// write under the bound, and a request that ran out may still land; it is the empty zone a
    /// claim needs, made again harmlessly at every claim, and decides nobody's role. A read that fails is a different thing, and with
    /// a login the login is the evidence there is. A read that ran out may be one whose record
    /// names another device, and a phone and a pad answer no probe, so taking it as that evidence
    /// would make two primaries. The claim itself is the lease's (`PrimaryLease`), which bounds its
    /// own requests.
    func decide() async {
        if role == .primary { await checkDemotion() }
        guard role == nil else { return }
        let signedIn = isSignedIn()
        let bound = Self.firstReadBound(after: ranOut)
        let read: FirstRead
        do {
            read = try await Self.within(bound, deadline: deadline) { [database, device, ensureZone] in
                try await Self.firstRead(database: database, device: device, signedIn: signedIn, ensureZone: ensureZone)
            }
        } catch is RanOut {
            ranOut += 1
            trouble = "iCloud hasn't answered in \(Int(bound)) seconds. Topo will keep asking."
            return
        } catch {
            // With a login and no record to read, the login is the evidence there is.
            if signedIn {
                keep(.primary)
            } else {
                trouble = TranscriptStore.message(for: error)
            }
            return
        }
        switch read {
        case .recordedViewer:
            keep(.viewer)
        case .lease(let record?):
            let holder = Lease(record: record)?.holder
            // A login decides only where the record names nobody.
            keep(holder == device || (signedIn && holder == nil) ? .primary : .viewer)
        case .lease(nil) where signedIn:
            keep(.primary)
        case .lease(nil):
            do {
                keep(try await stake() ? .primary : .viewer)
            } catch {
                trouble = TranscriptStore.message(for: error)
            }
        }
    }

    /// What the first reads found: this device's role recorded as viewer, or else the lease record,
    /// nil when there is none. With no record and no login, the zone has been made for the claim.
    private enum FirstRead: Sendable {
        case recordedViewer
        case lease(Record?)
    }

    private static func firstRead(database: any RecordDatabase, device: DeviceID, signedIn: Bool,
                                  ensureZone: @Sendable () async throws -> Void) async throws -> FirstRead {
        if let recorded = try? await DeviceRole.read(device, from: database), recorded.role == .viewer {
            return .recordedViewer
        }
        let record: Record?
        do {
            record = try await database.fetch(Lease.recordID)
        } catch where TopoCloudKit.meansNoLogYet(error) {
            // Nothing has been written on this Apple ID yet: no zone, so no record.
            record = nil
        }
        if record == nil, !signedIn { try await ensureZone() }
        return .lease(record)
    }

    /// How long the first reads are given, after `ranOut` attempts that ran out: 5 s, doubling to
    /// 60 s. The first screen says why it is waiting within seconds, and a store that answers
    /// slowly but surely is still read, by an attempt given longer than it takes.
    static func firstReadBound(after ranOut: Int) -> TimeInterval {
        min(5 * pow(2, Double(min(ranOut, 4))), 60)
    }

    /// The first reads did not answer within their bound.
    struct RanOut: Error {}

    /// What `work` answers if it answers before `deadline(bound)` returns, and `RanOut` otherwise.
    /// A `work` that does not stop when it is cancelled is not waited for: its answer, when it
    /// comes, goes nowhere.
    private static func within<T: Sendable>(_ bound: TimeInterval, deadline: @escaping @Sendable (TimeInterval) async throws -> Void,
                                            _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let answered = OSAllocatedUnfairLock(initialState: false)
        var tasks: [Task<Void, Never>] = []
        defer { tasks.forEach { $0.cancel() } }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let answer: @Sendable (Result<T, Error>) -> Void = { result in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            tasks.append(Task {
                do { answer(.success(try await work())) } catch { answer(.failure(error)) }
            })
            tasks.append(Task {
                guard (try? await deadline(bound)) != nil else { return }
                answer(.failure(RanOut()))
            })
        }
    }

    /// The first claim: true when this device created the lease record, false when another got
    /// there first.
    private func stake() async throws -> Bool {
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NeverConfirms(), timing: timing)
        return try await lease.claimIfNone()
    }

    /// The deliberate takeover, from a viewer's menu: this device becomes primary and the device
    /// that was stops answering. The one control that hands primary over, for a primary phone
    /// that is lost, wiped or simply retired.
    ///
    /// The safety is the wait: a fresh lease is left to lapse, one duration at most, and then
    /// read again. A lease fresh after the wait is a live primary, the holder that heartbeated
    /// or another that claimed meanwhile, and keeps primary; the takeover is refused and says
    /// so. A lapsed one is a holder that is gone, and is claimed over. With the
    /// claim, in one batch with the lease's heartbeat, the old holder's role record is written
    /// as viewer and this device's as primary, so the old device drops to viewer on its next
    /// launch or answering pass rather than answering again whenever this one goes quiet.
    /// On success the role is primary, the screen shows sign-in, and the lease instance that
    /// made the claim is returned for the harness to keep (the displaced device yields to that
    /// lease's epoch; a second claim from another instance would be one it never yielded to).
    /// On failure nil, the role unchanged, and `trouble` says why.
    @discardableResult
    func takePrimary() async -> PrimaryLease? {
        guard taking == nil else { return nil }
        defer { taking = nil }
        do {
            taking = "Checking who is primary…"
            let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NeverConfirms(), timing: timing)
            if let record = try await database.fetch(Lease.recordID), let current = Lease(record: record), current.holder != device {
                if !current.isExpired(at: Date()) {
                    let wait = min(current.expiresAt.timeIntervalSinceNow, timing.duration)
                    taking = "Waiting \(Int(wait.rounded(.up))) seconds for \(current.holder.rawValue) to finish…"
                    try await sleep(max(wait, 0))
                }
            }
            // After the wait, any fresh lease is a live primary, the one read before or another
            // that claimed meanwhile (a hub waking): it keeps primary and the takeover is refused.
            // A lapsed one is claimed over exactly as read, so a heartbeat landing between this
            // read and the claim is a conflict and refuses it too.
            let lapsed = try await database.fetch(Lease.recordID)
            if let lapsed, let after = Lease(record: lapsed), after.holder != device, !after.isExpired(at: Date()) {
                trouble = "\(after.holder.rawValue) is answering right now and kept primary."
                return nil
            }
            taking = "Taking over…"
            try await ensureZone()
            // Whoever is primary is read just before the claim, not before the wait: the lease's
            // holder now, and every device whose role record says primary, since a lease can pass
            // through hands without a role changing. The role records are prepared here so what
            // follows the claim is one save.
            let now = Date()
            var roles = [try await DeviceRole(device: device, role: .primary, setBy: device, at: now).record(over: database)]
            for other in try await primariesToDemote() {
                roles.append(try await DeviceRole(device: other, role: .viewer, setBy: device, at: now).record(over: database))
            }
            let claimed: Bool
            if let lapsed, let after = Lease(record: lapsed), after.holder != device {
                claimed = try await lease.claim(overLapsed: lapsed)
            } else if lapsed == nil {
                claimed = try await lease.claimIfNone()
            } else {
                // Our own lease, or a record that does not parse: the ordinary path.
                if case .primary = try await lease.acquire() { claimed = true } else { claimed = false }
            }
            guard claimed else {
                trouble = "Another device is answering right now and kept primary. Try again in a moment."
                return nil
            }
            do {
                // A claim whose role records do not land is abandoned, whatever stopped them: a
                // lease heartbeated by nobody would answer no turns and block every device.
                let landed: Bool
                do {
                    landed = try await lease.heartbeat(saving: roles) != nil
                } catch {
                    await lease.abandon()
                    throw error
                }
                guard landed else {
                    await lease.abandon()
                    trouble = "Another device took primary just now. Try again in a moment."
                    return nil
                }
                keep(.primary)
                return lease
            }
        } catch {
            trouble = TranscriptStore.message(for: error)
        }
        return nil
    }

    /// The devices a takeover demotes: the lease's holder as the record stands now, and every
    /// device recorded as primary. Never this device.
    private func primariesToDemote() async throws -> Set<DeviceID> {
        var others: Set<DeviceID> = []
        if let record = try await database.fetch(Lease.recordID), let current = Lease(record: record) {
            others.insert(current.holder)
        }
        for record in try await database.records(ofType: DeviceRole.recordType) {
            if let recorded = DeviceRole(record: record), recorded.role == .primary { others.insert(recorded.device) }
        }
        others.remove(device)
        return others
    }

    /// Reads this device's role record and drops to viewer if another device wrote it so: the
    /// far end of a takeover. True when the role changed, so the caller can forget the harness
    /// and the login. Read at launch and on every answering pass. Unreadable is no change.
    @discardableResult
    func checkDemotion() async -> Bool {
        guard await demotionRecorded() else { return false }
        acceptDemotion()
        return true
    }

    /// True when another device has written this primary's role as viewer. Changes nothing, so
    /// the caller can put what it has waiting into the log before the role flips and the chat
    /// goes; `acceptDemotion` then flips it.
    func demotionRecorded() async -> Bool {
        guard role == .primary, let recorded = try? await DeviceRole.read(device, from: database),
              recorded.role == .viewer, recorded.setBy != device else { return false }
        return true
    }

    func acceptDemotion() {
        guard role == .primary else { return }
        keep(.viewer)
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
