#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import TopoCore

/// The adapter's mapping, exercised on `CKRecord`s built offline. The
/// network half needs a container and is not tested here.
@Suite struct CloudKitMappingTests {
    let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)

    @Test func fieldsRoundTripThroughACKRecord() throws {
        let original = Record(type: "Turn", id: RecordID("turn/phone/1"), fields: [
            "device": .string("phone"), "sequence": .int(1), "at": .date(tA), "parents": .strings(["hub/3"]),
        ])
        let ck = CloudKitRecordDatabase.applying(original.fields, to: CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: original.id.name, zoneID: zone)))
        let back = CloudKitRecordDatabase.record(from: ck)
        #expect(back.type == "Turn")
        #expect(back.id == original.id)
        #expect(back.fields == original.fields)
        #expect(back.changeTag == nil)
    }

    @Test func applyingLeavesTheCachedRecordAloneAndKeepsUnmappedFields() throws {
        let cached = CKRecord(recordType: "PrimaryLease", recordID: CKRecord.ID(recordName: "primary", zoneID: zone))
        cached["holder"] = "hub" as NSString
        cached["endpoint"] = "hub:1" as NSString
        cached["ref"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: "x", zoneID: zone), action: .none)
        let written = CloudKitRecordDatabase.applying(["holder": .string("phone")], to: cached)
        #expect(written !== cached)
        #expect(written["holder"] as? String == "phone")
        #expect(written["endpoint"] == nil)
        #expect(written["ref"] != nil)
        #expect(cached["holder"] as? String == "hub")
        #expect(cached["endpoint"] as? String == "hub:1")
    }

    @Test func serverRecordChangedCarriesTheServerVersion() throws {
        let server = CKRecord(recordType: "PrimaryLease", recordID: CKRecord.ID(recordName: "primary", zoneID: zone))
        server["holder"] = "hub" as NSString
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let mapped = CloudKitRecordDatabase.mapped(error, recordIDs: [server.recordID])
        guard case RecordDatabaseError.serverRecordChanged(let id, let record) = mapped else {
            Issue.record("got \(mapped)"); return
        }
        #expect(id == RecordID("primary"))
        #expect(record.string("holder") == "hub")
    }

    @Test func partialFailureSurfacesTheRecordConflictInsideIt() throws {
        let server = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: "turn/phone/1", zoneID: zone))
        let inner = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [server.recordID: inner]])
        let mapped = CloudKitRecordDatabase.mapped(partial, recordIDs: [server.recordID])
        guard case RecordDatabaseError.serverRecordChanged(let id, _) = mapped else { Issue.record("got \(mapped)"); return }
        #expect(id == RecordID("turn/phone/1"))
    }

    @Test func permanentErrorsAreRejectedNotUnavailable() throws {
        for code in [CKError.Code.notAuthenticated, .zoneNotFound, .quotaExceeded, .invalidArguments] {
            let mapped = CloudKitRecordDatabase.mapped(CKError(code), recordIDs: [])
            guard case RecordDatabaseError.rejected = mapped else { Issue.record("\(code) mapped to \(mapped)"); continue }
        }
        for code in [CKError.Code.networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy] {
            let mapped = CloudKitRecordDatabase.mapped(CKError(code), recordIDs: [])
            guard case RecordDatabaseError.unavailable = mapped else { Issue.record("\(code) mapped to \(mapped)"); continue }
        }
    }

    @Test func predicatesMatchTheQueryShape() throws {
        let q = RecordQuery(type: "Turn", filters: [.init("device", .equals, .string("phone")), .init("sequence", .greaterThan, .int(4))])
        let p = CloudKitRecordDatabase.predicate(for: q)
        let hit = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: "a", zoneID: zone))
        hit["device"] = "phone" as NSString; hit["sequence"] = NSNumber(value: 5)
        let miss = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: "b", zoneID: zone))
        miss["device"] = "phone" as NSString; miss["sequence"] = NSNumber(value: 4)
        #expect(p.evaluate(with: hit))
        #expect(!p.evaluate(with: miss))
        #expect(CloudKitRecordDatabase.predicate(for: RecordQuery(type: "Turn")).evaluate(with: miss))
    }
}
#endif
