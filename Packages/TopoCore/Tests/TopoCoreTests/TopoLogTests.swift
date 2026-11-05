import Foundation
import os
import Testing
@testable import TopoCore
#if canImport(CloudKit)
import CloudKit
#endif

/// The categories' levels (#604): bounded, in memory, and back to `default` at their expiry.
@Suite struct TopoLogTests {
    final class Clock: Sendable {
        let at = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        func advance(_ seconds: TimeInterval) { at.withLock { $0 += seconds } }
    }

    final class Told: Sendable {
        let ended = OSAllocatedUnfairLock<[String]>(initialState: [])
    }

    func levels(_ clock: Clock, _ told: Told = Told()) -> LogLevels {
        LogLevels(now: { clock.at.withLock { $0 } }, expired: { category, level in
            told.ended.withLock { $0.append("\(category.rawValue) \(level.rawValue)") }
        })
    }

    @Test func everyCategoryStartsAtDefault() {
        let levels = levels(Clock())
        for category in LogCategory.allCases {
            #expect(levels.setting(category) == LogLevels.Setting(level: .default, until: nil))
        }
    }

    /// Debug is never unbounded: thirty minutes unless given, two hours at most.
    @Test func debugEndsAtItsExpiryAndSaysSoOnce() {
        let clock = Clock(), told = Told()
        let levels = levels(clock, told)
        let set = levels.set(.audio, .debug)
        #expect(set.until == clock.at.withLock { $0 }.addingTimeInterval(30 * 60))
        clock.advance(30 * 60 - 1)
        #expect(levels.level(.audio) == .debug)
        #expect(levels.level(.cloud) == .default)
        clock.advance(1)
        #expect(levels.level(.audio) == .default)
        #expect(levels.level(.audio) == .default)
        #expect(told.ended.withLock { $0 } == ["audio debug"])
        let long = levels.set(.cloud, .debug, for: 24 * 60 * 60)
        #expect(long.until == clock.at.withLock { $0 }.addingTimeInterval(LogLevels.longest))
    }

    @Test func offHoldsUntilTheLaunchUnlessGivenATimeAndDefaultClears() {
        let clock = Clock()
        let levels = levels(clock)
        #expect(levels.set(.perf, .off).until == nil)
        clock.advance(10 * 24 * 60 * 60)
        #expect(levels.level(.perf) == .off)
        levels.set(.perf, .default, for: 60)
        #expect(levels.setting(.perf) == LogLevels.Setting(level: .default, until: nil))
        levels.set(.perf, .off, for: 60)
        clock.advance(60)
        #expect(levels.level(.perf) == .default)
    }

    /// A detail line is not even made unless the category is at debug, and off silences all but
    /// the errors.
    @Test func theWriterReadsTheLevelAtEveryLine() {
        let clock = Clock()
        let levels = levels(clock)
        let log = TopoLog(.cloud, levels: levels)
        let made = OSAllocatedUnfairLock(initialState: 0)
        func line() -> String { made.withLock { $0 += 1 }; return "line" }
        log.detail(line())
        #expect(made.withLock { $0 } == 0)
        log.notice(line())
        #expect(made.withLock { $0 } == 1)
        levels.set(.cloud, .debug)
        #expect(log.detailed)
        log.detail(line())
        #expect(made.withLock { $0 } == 2)
        levels.set(.cloud, .off)
        log.info(line())
        log.notice(line())
        log.detail(line())
        #expect(made.withLock { $0 } == 2)
        log.error(line())
        #expect(made.withLock { $0 } == 3)
    }

    #if canImport(CloudKit)
    /// The cloud lines carry the mapped case and CloudKit's code, never the error's description,
    /// which for a conflict holds the server's record and every field in it.
    @Test func aCloudErrorIsItsCaseAndCodeAndNoField() {
        let server = Record(type: "Turn", id: RecordID("turn/phone/7"), fields: ["text": .string("SENTINEL words said")])
        #expect(CloudLog.describe(RecordDatabaseError.serverRecordChanged(server.id, server: server)) == "serverRecordChanged turn/phone/7")
        let record = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: "turn/phone/7"))
        record["text"] = "SENTINEL words said" as NSString
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: record])
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [record.recordID: conflict, CKRecord.ID(recordName: "b"): CKError(.batchRequestFailed)]])
        let said = CloudLog.describe(RecordDatabaseError.unavailable(underlying: partial))
        #expect(said == "unavailable (CKError partialFailure 2: serverRecordChanged 14, batchRequestFailed 22)")
        #expect(!said.contains("SENTINEL"))
        #expect(CloudLog.describe(RecordDatabaseError.rejected(underlying: CKError(.notAuthenticated))) == "rejected (CKError notAuthenticated 9)")
        #expect(CloudLog.describe(RecordDatabaseError.unavailable(underlying: URLError(.timedOut))) == "unavailable (NSURLErrorDomain -1001)")
        #expect(CloudLog.describe(RecordDatabaseError.unknownItem(RecordID("lease"))) == "unknownItem lease")
        #expect(CloudLog.describe(CancellationError()) == "cancelled")
    }

    /// Every mapped case names its code: a code the table lacks would say `code` and its number.
    @Test func everyCodeTheMappingKnowsHasAName() {
        for code in CloudKitRecordDatabase.permanentCodes.union([.networkUnavailable, .networkFailure, .serviceUnavailable,
                                                                  .requestRateLimited, .zoneBusy, .serverResponseLost, .internalError]) {
            #expect(CloudLog.name(code) != "code", "\(code.rawValue)")
        }
    }
    #endif
}
