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
        let refused = await #expect(throws: RecordDatabaseError.self) { try await again.save(saved) }
        #expect(refused?.case == .serverRecordChanged)
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
        // Scribble over the middle of the first save's body.
        let first = try LocalRecordDatabaseTests.frameStarts(bytes)[1]
        for i in (first + 20)..<(first + 40) { bytes[i] = 0xFF }
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
    }

    /// A middle frame whose length is damaged so that it points past the end of the file is
    /// damage, never a torn last frame: reading it as one would cut every frame after it away.
    @Test func aDamagedLengthBeforeTheLastFrameRefusesTheFileAndCutsNothing() async throws {
        let db = try open()
        for name in ["a", "b", "c", "d"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        var bytes = try Data(contentsOf: file)
        let b = try LocalRecordDatabaseTests.frameStarts(bytes)[2]
        bytes[b] = 0x7F
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == bytes, "nothing was cut")
    }

    /// Codex's case: a middle frame whose length and complement are both damaged, and agree, so
    /// the frame claims to run past the end of the file. A whole frame follows it, so it is not
    /// the last write, and it is refused with nothing cut.
    @Test func aMiddleLengthDamagedWithItsComplementIsRefusedAndCutsNothing() async throws {
        let db = try open()
        for name in ["a", "b", "c"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        var bytes = try Data(contentsOf: file)
        let b = try LocalRecordDatabaseTests.frameStarts(bytes)[2]
        bytes.replaceSubrange(b..<b + 8, with: [0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00])
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == bytes, "nothing was cut")
        // And agreeing lengths that land inside the next frame or exactly on the end of the file.
        for wrong in [UInt32(3), UInt32(bytes.count - b - LocalRecordDatabase.prefix)] {
            var moved = bytes
            let be = { (v: UInt32) in [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            moved.replaceSubrange(b..<b + 8, with: be(wrong) + be(~wrong))
            try moved.write(to: file)
            #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
            #expect(try Data(contentsOf: file) == moved, "nothing was cut")
        }
    }

    /// A compacted journal is one header frame holding the store. A flipped bit in it is damage,
    /// never a torn write, so the file is refused with nothing cut rather than opened empty.
    @Test func aDamagedCompactedHeaderIsRefusedAndCutsNothing() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "Turn", id: RecordID("turn/p/1"), fields: ["t": .string("hi")]))
        var a = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 {
            a.fields["v"] = .int(Int64(v))
            a = try await db.save(a)
        }
        _ = try open()
        var bytes = try Data(contentsOf: file)
        #expect(try LocalRecordDatabaseTests.frameStarts(bytes) == [0], "compacted to one frame")
        for at in [bytes.count - 20, 2, 9, LocalRecordDatabase.prefix + 3] {
            var flipped = bytes
            flipped[at] ^= 1
            try flipped.write(to: file)
            #expect(throws: LocalRecordDatabase.Failure.self, "a bit flipped at \(at)") { try open() }
            #expect(try Data(contentsOf: file) == flipped, "nothing was cut")
        }
        try bytes.write(to: file)
        bytes = Data()
        #expect(await (try open()).current(RecordID("turn/p/1")) != nil)
    }

    /// A last write whose prefix did not land whole (zeroed, or its length without its
    /// complement, as a write straddling a page can leave) is torn, not damage that keeps the
    /// phone from its records for good.
    @Test func aLastFrameWhosePrefixDidNotLandIsTorn() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        let before = try Data(contentsOf: file)
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        let whole = try Data(contentsOf: file)
        for zeroed in [0..<4, 0..<8, 0..<12, 0..<40, 4..<8] {
            var bytes = whole
            let cut = before.count + zeroed.lowerBound..<before.count + zeroed.upperBound
            bytes.resetBytes(in: cut)
            try bytes.write(to: file)
            let reopened = try open()
            #expect(await reopened.current(RecordID("a")) != nil, "\(cut)")
            #expect(await reopened.current(RecordID("b")) == nil, "\(cut)")
            #expect(try Data(contentsOf: file) == before, "\(cut) is cut away")
        }
    }

    /// A long run of zeros at the end opens in one pass over the file, not one per byte.
    @Test func aLongZeroTailOpensQuickly() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        let before = try Data(contentsOf: file)
        try (before + Data(count: 128 << 10)).write(to: file)
        let started = ContinuousClock.now
        let reopened = try open()
        #expect(ContinuousClock.now - started < .seconds(1), "a 128 KB zero tail took \(ContinuousClock.now - started)")
        #expect(await reopened.current(RecordID("a")) != nil)
        #expect(try Data(contentsOf: file) == before)
    }

    /// A middle body that fails its checksum, its length intact, is damage.
    @Test func aBodyThatFailsItsChecksumBeforeTheEndIsDamage() async throws {
        let db = try open()
        for name in ["a", "b", "c"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        var bytes = try Data(contentsOf: file)
        let b = try LocalRecordDatabaseTests.frameStarts(bytes)[2]
        bytes[b + 12] ^= 0x01
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
    }

    /// Zeros the file was extended with past the last whole frame are a torn write, cut away.
    @Test func aZeroFilledTailIsTorn() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        let whole = try Data(contentsOf: file)
        for zeros in [1, 5, 8, 64] {
            try (whole + Data(count: zeros)).write(to: file)
            let reopened = try open()
            #expect(await reopened.current(RecordID("a")) != nil)
            #expect(try Data(contentsOf: file) == whole)
        }
    }

    /// A compaction that cannot be written leaves the journal as it was and the store open.
    @Test func aCompactionThatFailsStillOpensTheJournal() async throws {
        let db = try open()
        var record = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 {
            record.fields["v"] = .int(Int64(v))
            record = try await db.save(record)
        }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let reopened = try open()
        #expect(await reopened.current(RecordID("a")) == record)
    }

    @Test func aTagOrATokenFromAnotherFileIsNotHonoured() async throws {
        let mine = try open()
        let other = try LocalRecordDatabase(file: file.deletingLastPathComponent().appending(path: "other.journal"))
        let theirs = try await other.save(Record(type: "T", id: RecordID("a")))
        _ = try await mine.save(Record(type: "T", id: RecordID("a")))
        let refused = await #expect(throws: RecordDatabaseError.self) { try await mine.save(theirs) }
        #expect(refused?.case == .serverRecordChanged)
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

    /// Where each frame begins: the header's first, then each save's.
    static func frameStarts(_ bytes: Data) throws -> [Int] {
        var out: [Int] = []
        var offset = 0
        while offset + LocalRecordDatabase.prefix <= bytes.count {
            out.append(offset)
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += LocalRecordDatabase.prefix + length
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


/// The journal's own failures, made to happen through `JournalIO`.
@Suite struct LocalRecordFaultTests {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "local-faults-\(UUID().uuidString)/records.journal")

    struct Fault: Error {}

    /// What the next writes do: a partial write that then fails, and whether the cut back fails.
    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = false
        private var cutFails = false
        private var replaceFails = false
        private(set) var replaces = 0
        func next(partial: Bool = false, cutFails: Bool = false, replaceFails: Bool = false) {
            lock.withLock { (self.partial, self.cutFails, self.replaceFails) = (partial, cutFails, replaceFails) }
        }
        var io: JournalIO {
            var io = JournalIO.system
            io.append = { [self] handle, data in
                let tear = lock.withLock { () -> Bool in defer { partial = false }; return partial }
                if tear {
                    try handle.write(contentsOf: data.prefix(data.count / 2))
                    throw Fault()
                }
                try handle.write(contentsOf: data)
            }
            io.truncate = { [self] handle, offset in
                if lock.withLock({ cutFails }) { throw Fault() }
                try handle.truncate(atOffset: offset)
            }
            io.replace = { [self] data, url, options in
                let fails = lock.withLock { () -> Bool in replaces += 1; return replaceFails }
                if fails { throw Fault() }
                try data.write(to: url, options: options)
            }
            return io
        }
    }

    /// Half a frame reaches the file and the write fails; the cut back works. The save is
    /// unavailable, the next save lands after the last whole frame, and a reopen holds both
    /// whole saves and nothing of the failed one.
    @Test func aPartialWriteIsCutBackAndTheNextWriteFollowsTheLastWholeFrame() async throws {
        let faults = Faults()
        let db = try LocalRecordDatabase(file: file, io: faults.io)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        let before = try Data(contentsOf: file)
        faults.next(partial: true)
        let failed = await #expect(throws: RecordDatabaseError.self) { try await db.save(Record(type: "T", id: RecordID("lost"))) }
        #expect(failed?.case == .unavailable)
        #expect(try Data(contentsOf: file) == before, "the half frame is cut away")
        #expect(await db.current(RecordID("lost")) == nil)
        _ = try await db.save(Record(type: "T", id: RecordID("after")))
        let reopened = try LocalRecordDatabase(file: file)
        #expect(await reopened.current(RecordID("a")) != nil)
        #expect(await reopened.current(RecordID("after")) != nil)
        #expect(await reopened.current(RecordID("lost")) == nil)
    }

    /// Half a frame reaches the file and the cut back fails too: the journal takes no more
    /// writes this launch, so the half frame stays the last thing in the file, and a reopen
    /// cuts it as a torn last write and holds every save that answered.
    @Test func aPartialWriteThatCannotBeCutBackStopsEveryWriteAfterIt() async throws {
        let faults = Faults()
        let db = try LocalRecordDatabase(file: file, io: faults.io)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        faults.next(partial: true, cutFails: true)
        let failed = await #expect(throws: RecordDatabaseError.self) { try await db.save(Record(type: "T", id: RecordID("lost"))) }
        #expect(failed?.case == .unavailable)
        faults.next()
        do {
            _ = try await db.save(Record(type: "T", id: RecordID("refused")))
            Issue.record("a journal that could not cut back took another write")
        } catch RecordDatabaseError.rejected(let underlying) {
            #expect(LocalRecordDatabase.isJournalFailure(underlying))
        }
        let reopened = try LocalRecordDatabase(file: file)
        #expect(await reopened.current(RecordID("a")) != nil)
        #expect(await reopened.current(RecordID("lost")) == nil)
        #expect(await reopened.current(RecordID("refused")) == nil)
    }

    /// A torn tail the open cannot cut refuses the file: a frame written after an uncut torn one
    /// would be damage at the next open.
    @Test func aTornTailThatCannotBeCutRefusesTheOpen() async throws {
        let db = try LocalRecordDatabase(file: file)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        try (try Data(contentsOf: file) + Data([1, 2, 3])).write(to: file)
        let faults = Faults()
        faults.next(cutFails: true)
        #expect(throws: LocalRecordDatabase.Failure.self) { try LocalRecordDatabase(file: file, io: faults.io) }
        #expect(await (try LocalRecordDatabase(file: file)).current(RecordID("a")) != nil)
    }

    /// A compaction that fails is tried, and leaves the journal's bytes as they were and a
    /// token from before it still read.
    @Test func aFailedCompactionLeavesTheJournalAndItsTokens() async throws {
        let first = try LocalRecordDatabase(file: file)
        var record = try await first.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        let token = try await first.changes(ofType: "T", since: nil).token
        for v in 1...10 {
            record.fields["v"] = .int(Int64(v))
            record = try await first.save(record)
        }
        let before = try Data(contentsOf: file)
        let faults = Faults()
        faults.next(replaceFails: true)
        let reopened = try LocalRecordDatabase(file: file, io: faults.io)
        #expect(faults.replaces == 1, "the compaction was tried")
        #expect(try Data(contentsOf: file) == before)
        #expect(await reopened.current(RecordID("a")) == record)
        #expect(try await reopened.changes(ofType: "T", since: token).changed == [record])
    }

    /// The protection the journal asks for, on its folder, at its creation and at a compaction,
    /// and that nothing excludes the file or its folder from backups. The simulator and macOS
    /// keep no protection class, so what is held here is what was asked for.
    @Test func theJournalAsksForItsProtectionAndStaysInBackups() async throws {
        let asked = Asked()
        var io = JournalIO.system
        io.replace = { data, url, options in
            asked.note(options)
            try data.write(to: url, options: options)
        }
        io.makeFolder = { url, attributes in
            asked.note(folder: attributes[.protectionKey] as? FileProtectionType)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        }
        let db = try LocalRecordDatabase(file: file, io: io)
        var record = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 {
            record.fields["v"] = .int(Int64(v))
            record = try await db.save(record)
        }
        _ = try LocalRecordDatabase(file: file, io: io)
        let writes = asked.writes
        #expect(writes.count == 2, "the creation and the compaction")
        for options in writes {
            #expect(options.contains(.atomic))
            #expect(options == LocalRecordDatabase.writing)
        }
        #expect(asked.folders.allSatisfy { $0 == LocalRecordDatabase.protectionClass })
        #if os(iOS)
        #expect(LocalRecordDatabase.protectionClass == .completeUntilFirstUserAuthentication)
        #expect(writes.allSatisfy { $0.contains(.completeFileProtectionUntilFirstUserAuthentication) })
        #endif
        for url in [file, file.deletingLastPathComponent()] {
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var options: [Data.WritingOptions] = []
        private var classes: [FileProtectionType?] = []
        func note(_ o: Data.WritingOptions) { lock.withLock { options.append(o) } }
        func note(folder: FileProtectionType?) { lock.withLock { classes.append(folder) } }
        var writes: [Data.WritingOptions] { lock.withLock { options } }
        var folders: [FileProtectionType?] { lock.withLock { classes } }
    }
}
