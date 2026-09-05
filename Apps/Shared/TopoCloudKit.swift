@preconcurrency import CloudKit
import Foundation
import TopoCore

/// The one container and zone every bundle shares: client, hub, Womble. The
/// identifiers are a contract between them, not a per-target setting.
enum TopoCloudKit {
    static let containerIdentifier = "iCloud.zone.hexagon.topo"
    /// The log lives in a custom zone; the default zone has no atomic
    /// batches, which the writers need.
    static let zoneName = "Topo"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// The private database of the shared container. Private: the log is one
    /// person's, on their own Apple ID, and nothing of it passes through a
    /// server of ours.
    static func database() -> CloudKitRecordDatabase {
        let container = CKContainer(identifier: containerIdentifier)
        return CloudKitRecordDatabase(database: container.privateCloudDatabase, zoneID: zoneID)
    }

    /// Creates the zone unless it is already there. A device that only reads
    /// never needs this; the first device to write does, because the zone is
    /// where every record goes.
    static func ensureZone() async throws {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    /// The iCloud account as CloudKit sees it, in words, for the diagnostics screen.
    static func accountStatus() async -> String {
        do {
            switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available: return "available"
            case .noAccount: return "no iCloud account on this device"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "could not determine"
            case .temporarilyUnavailable: return "temporarily unavailable"
            @unknown default: return "unknown"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// True when the error means the log does not exist yet rather than
    /// something being wrong with it: nobody has written a turn, so the zone
    /// the writers create is not there.
    static func meansNoLogYet(_ error: any Error) -> Bool {
        var errors: [any Error] = [error]
        if case RecordDatabaseError.rejected(let underlying) = error { errors.append(underlying) }
        if case RecordDatabaseError.unavailable(let underlying) = error { errors.append(underlying) }
        return errors.contains { ($0 as? CKError).map { [.zoneNotFound, .userDeletedZone].contains($0.code) } ?? false }
    }
}
