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

/// The household board: a container of its own, and not the log's.
///
/// The board is the one thing several people hold at once, so it is shared
/// across Apple IDs — one person creates the zone and shares it with the
/// house, and everyone else writes into it through their own login. The
/// transcript and the memory never are, and keeping them in a different
/// container is what makes that true by construction rather than by care:
/// nothing that can reach a shared zone can reach the personal one.
enum TopoBoard {
    static let containerIdentifier = "iCloud.zone.hexagon.topo.board"
    static let zoneName = "Board"

    static var container: CKContainer { CKContainer(identifier: containerIdentifier) }

    /// The zone as its owner names it.
    static var ownZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// The board this Apple ID keeps itself, whether or not it is shared.
    static func own() -> CloudKitRecordDatabase {
        CloudKitRecordDatabase(database: container.privateCloudDatabase, zoneID: ownZoneID)
    }

    static func ensureZone() async throws {
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: ownZoneID)],
                                                                       deleting: [])
    }

    /// The share for this house's board, made if it is not there yet. Hand
    /// its URL to the other people in the house; accepting it puts the zone
    /// in their shared database, where `joined()` finds it.
    ///
    /// The whole zone is shared rather than a record at a time, because a
    /// board is one thing: a person who can see it can post to it.
    static func share() async throws -> CKShare {
        try await ensureZone()
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ownZoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare { return existing }
        let share = CKShare(recordZoneID: ownZoneID)
        share[CKShare.SystemFieldKey.title] = "The house board" as CKRecordValue
        let saved = try await database.modifyRecords(saving: [share], deleting: [],
                                                     savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard case .success(let record)? = saved.saveResults[share.recordID], let share = record as? CKShare else {
            throw CKError(.internalError)
        }
        return share
    }

    /// Somebody else's board, if this Apple ID has accepted a share of one.
    /// A house has one board; the first shared zone by that name is it.
    static func joined() async throws -> CloudKitRecordDatabase? {
        let shared = container.sharedCloudDatabase
        let zones = try await shared.allRecordZones()
        guard let zone = zones.first(where: { $0.zoneID.zoneName == zoneName }) else { return nil }
        return CloudKitRecordDatabase(database: shared, zoneID: zone.zoneID)
    }

    /// The board to read and write: the one this Apple ID was given, or its
    /// own. A house where nobody has shared one yet still has a board — it
    /// is simply not shared, which is what one person's first card looks
    /// like before anybody else is invited.
    ///
    /// A lookup that fails throws rather than quietly answering with this
    /// device's own board. Only a lookup that succeeded and found nothing
    /// means there is nothing to join: treating a network hiccup as that
    /// would put this device's cards in a zone of its own, and a split
    /// board looks to everyone like the other people's cards vanishing.
    static func database() async throws -> CloudKitRecordDatabase {
        if let joined = try await joined() { return joined }
        return own()
    }
}
