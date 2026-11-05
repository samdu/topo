import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// The `cloud` category's words for an error: the mapped `RecordDatabaseError` case and the
/// codes under it, never the error itself. A `CKError`'s description carries its user info, and
/// a conflict's server record is in there with every field it holds — a turn's words among them.
public enum CloudLog {
    public static func describe(_ error: any Error) -> String {
        switch error {
        case RecordDatabaseError.serverRecordChanged(let id, _): "serverRecordChanged \(id.name)"
        case RecordDatabaseError.unknownItem(let id): "unknownItem \(id.name)"
        case RecordDatabaseError.unavailable(let underlying): "unavailable (\(code(underlying)))"
        case RecordDatabaseError.rejected(let underlying): "rejected (\(code(underlying)))"
        case is CancellationError: "cancelled"
        default: "unmapped (\(code(error)))"
        }
    }

    /// An error as its domain's name for its code: `CKError networkUnavailable 3`, with a partial
    /// failure's distinct item codes after it; anything else as its domain and number.
    public static func code(_ error: any Error) -> String {
        let ns = error as NSError
        #if canImport(CloudKit)
        if ns.domain == CKError.errorDomain {
            let ck = CKError(_nsError: ns)
            var said = "CKError \(name(ck.code)) \(ck.code.rawValue)"
            let items = Set((ck.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError)?.code })
            if !items.isEmpty {
                said += ": " + items.sorted { $0.rawValue < $1.rawValue }.map { "\(name($0)) \($0.rawValue)" }.joined(separator: ", ")
            }
            return said
        }
        #endif
        return "\(ns.domain) \(ns.code)"
    }

    #if canImport(CloudKit)
    static func name(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .resultsTruncated: "resultsTruncated"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        default: "code"
        }
    }
    #endif
}
