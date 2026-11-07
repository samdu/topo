import Foundation
import Testing
@testable import TopoCore

/// What the journal adds to the contract: the store survives a reopen, a torn last write is
/// never half applied, and nothing of one file is honoured by another.
@Suite struct LocalRecordDatabaseTests {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "local-records-\(UUID().uuidString)/records.journal")

    private func open() throws -> LocalRecordDatabase { try LocalRecordDatabase(file: file) }

    @Test func whatWasSavedIsThereAfterAReopen() async throws {
        let first = try open()
        let saved = try await first.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(1)]))
        _ = try await first.save(Record(type: "T", id: RecordID("b")))
        try await first.delete([RecordID("b")])
        let again = try open()
        #expect(await again.current(RecordID("a")) == saved)
        #expect(await again.current(RecordID("b")) == nil)
        // Its tag still compares: a save over it works, a create over it is refused.
        var next = saved
        next.fields["v"] = .int(2)
        let moved = try await again.save(next)
        #expect(moved.changeTag != saved.changeTag)
        await #expect(throws: RecordDatabaseError.self) { try await again.save(saved) }
    }

    @Test func aTokenStillReadsAcrossAReopen() async throws {
        let first = try open()
        _ = try await first.save(Record(type: "T", id: RecordID("a")))
        let token = try await first.changes(ofType: "T", since: nil).token
        _ = try await first.save(Record(type: "T", id: RecordID("b")))
        let again = try open()
        #expect(try await again.changes(ofType: "T", since: token).changed.map(\.id.name) == ["b"])
    }

    /// A batch cut short at any byte of its frame reopens to the store before it: never a turn
    /// without its marker, never a marker without its turn.
    @Test func tornTailIsNotApplied() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("before")))
        let before = try Data(contentsOf: file)
        _ = try await db.save([Record(type: "Turn", id: RecordID("turn/d/1"), fields: ["text": .string("hello")]),
                               Record(type: "TurnWrite", id: RecordID("turnwrite/n"), fields: ["turn": .string("d/1")])])
        let whole = try Data(contentsOf: file)
        #expect(whole.count > before.count)
        for cut in before.count..<whole.count {
            try whole.prefix(cut).write(to: file)
            let reopened = try open()
            #expect(await reopened.current(RecordID("before")) != nil)
            #expect(await reopened.current(RecordID("turn/d/1")) == nil, "cut at \(cut)")
            #expect(await reopened.current(RecordID("turnwrite/n")) == nil, "cut at \(cut)")
            #expect(try Data(contentsOf: file).count == before.count, "the torn frame is cut away")
            // And the next write lands after the last whole frame, readable at the next open.
            _ = try await reopened.save(Record(type: "T", id: RecordID("after-\(cut)")))
            #expect(await (try open()).current(RecordID("after-\(cut)")) != nil)
            try before.write(to: file)
        }
        try whole.write(to: file)
        #expect(await (try open()).current(RecordID("turnwrite/n")) != nil)
    }

    @Test func damageBeforeTheLastFrameRefusesTheFile() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .string(String(repeating: "x", count: 64))]))
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        var bytes = try Data(contentsOf: file)
        // Scribble over the middle of the first save's frame.
        let header = try LocalRecordDatabaseTests.frameLengths(bytes)[0] + 4
        for i in (header + 8)..<(header + 40) { bytes[i] = 0xFF }
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.OpenError.self) { try open() }
    }

    @Test func aTagOrATokenFromAnotherFileIsNotHonoured() async throws {
        let mine = try open()
        let other = try LocalRecordDatabase(file: file.deletingLastPathComponent().appending(path: "other.journal"))
        let theirs = try await other.save(Record(type: "T", id: RecordID("a")))
        _ = try await mine.save(Record(type: "T", id: RecordID("a")))
        await #expect(throws: RecordDatabaseError.self) { try await mine.save(theirs) }
        let token = try await other.changes(ofType: "T", since: nil).token
        await #expect(throws: RecordChangesError.self) { try await mine.changes(ofType: "T", since: token) }
    }

    @Test func aJournalOfMostlyReplacedRecordsIsCompactedAndItsTokensExpire() async throws {
        let db = try open()
        var record = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        let token = try await db.changes(ofType: "T", since: nil).token
        for v in 1...10 {
            record.fields["v"] = .int(Int64(v))
            record = try await db.save(record)
        }
        let long = try Data(contentsOf: file).count
        let reopened = try open()
        #expect(try Data(contentsOf: file).count < long)
        #expect(await reopened.current(RecordID("a")) == record)
        await #expect(throws: RecordChangesError.self) { try await reopened.changes(ofType: "T", since: token) }
        #expect(try await reopened.changes(ofType: "T", since: nil).changed == [record])
        // The tag counter carries on: the next save's tag is new, and the old one compares.
        record.fields["v"] = .int(11)
        let next = try await reopened.save(record)
        #expect(next.changeTag != record.changeTag)
        #expect(await (try open()).current(RecordID("a")) == next)
    }

    static func frameLengths(_ bytes: Data) throws -> [Int] {
        var out: [Int] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            out.append(length)
            offset += 4 + length
        }
        return out
    }
}

/// The log and the lease over the disk store, across a relaunch: what a phone with no iCloud
/// account does at every launch.
@Suite struct LocalLogAndLeaseTests {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "local-log-\(UUID().uuidString)/records.journal")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func theLogCarriesOnFromWhereTheLastLaunchStopped() async throws {
        let first = try LocalRecordDatabase(file: file)
        let w = try await TurnLog(database: first).writer(for: phone)
        let a = try await w.append(.person, "hi", parents: [], at: t0)
        let b = try await w.append(.assistant, "hello", parents: [a.ref], at: t0 + 1)
        let relaunched = try LocalRecordDatabase(file: file)
        let log = TurnLog(database: relaunched)
        let read = try await log.read()
        #expect(read[a.ref]?.text == "hi")
        #expect(read[b.ref]?.text == "hello")
        let again = try await log.writer(for: phone)
        #expect(await again.nextRef == .ref("phone", 3))
    }

    @Test func theFirstClaimIsTheOneDevicesAndItHoldsAcrossARelaunch() async throws {
        let first = try LocalRecordDatabase(file: file)
        let p = PrimaryLease(database: first, device: phone, endpoint: nil, probe: StubProbe.allDead,
                             sleep: Ticker().sleep)
        #expect(try await p.claimIfNone())
        let relaunched = try LocalRecordDatabase(file: file)
        let q = PrimaryLease(database: relaunched, device: phone, endpoint: nil, probe: StubProbe.allDead,
                             sleep: Ticker().sleep)
        guard case .primary = try await q.acquire() else { Issue.record("the phone's own lease"); return }
        let record = try await relaunched.fetch(Lease.recordID)
        #expect(Lease(record: try #require(record))?.holder == phone)
    }
}
