import Foundation
import Testing
@testable import TopoCore

/// What the journal adds to the contract: the store survives a reopen, a save that did not
/// commit is never half applied, recovery reads only what was committed, and nothing of one file
/// is honoured by another.
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

    /// What a save that did not commit leaves: the file as it was before the save, then the part
    /// of the save's frame that landed (its slot never written).
    private func torn(_ records: [Record], landing count: (Data) -> Int) async throws -> (before: Data, torn: Data) {
        let before = try Data(contentsOf: file)
        let db = try open()
        _ = try await db.save(records)
        let after = try Data(contentsOf: file)
        let frame = after[before.count...]
        let torn = before + frame.prefix(count(Data(frame)))
        try torn.write(to: file)
        return (before, torn)
    }

    /// A batch cut short at any byte of its frame, or landed whole without its slot, reopens to
    /// the store before it: never a turn without its marker, never a marker without its turn.
    @Test func tornTailIsNotApplied() async throws {
        _ = try await open().save(Record(type: "T", id: RecordID("before")))
        let batch = [Record(type: "Turn", id: RecordID("turn/d/1"), fields: ["text": .string("hello")]),
                     Record(type: "TurnWrite", id: RecordID("turnwrite/n"), fields: ["turn": .string("d/1")])]
        let base = try Data(contentsOf: file)
        let length = try await torn(batch) { $0.count }.torn.count - base.count
        for cut in 0...length {
            try base.write(to: file)
            let (before, _) = try await torn(batch) { _ in cut }
            let reopened = try open()
            #expect(await reopened.current(RecordID("before")) != nil)
            #expect(await reopened.current(RecordID("turn/d/1")) == nil, "cut at \(cut)")
            #expect(await reopened.current(RecordID("turnwrite/n")) == nil, "cut at \(cut)")
            #expect(try Data(contentsOf: file) == before, "what did not commit is cut away")
            _ = try await reopened.save(Record(type: "T", id: RecordID("after-\(cut)")))
            #expect(await (try open()).current(RecordID("after-\(cut)")) != nil)
        }
    }

    /// Whatever lies past the committed length is cut, never read: zeros, a prefix that did not
    /// land, or bytes of any kind.
    @Test func anythingPastTheCommittedLengthIsCut() async throws {
        _ = try await open().save(Record(type: "T", id: RecordID("a")))
        let whole = try Data(contentsOf: file)
        let tails = [Data(count: 1), Data(count: 5), Data(count: 64), Data(count: 128 << 10),
                     Data(repeating: 0xFF, count: 40), Data([0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0, 0, 0, 1, 2, 3, 4])]
        for tail in tails {
            try (whole + tail).write(to: file)
            let replayed = try LocalRecordDatabase.replay(whole + tail)
            #expect(replayed.examined == whole.count - LocalRecordDatabase.slots, "nothing past the committed length is read")
            #expect(await (try open()).current(RecordID("a")) != nil)
            #expect(try Data(contentsOf: file) == whole)
        }
    }

    /// Codex's case: save a, then a record b whose asset carries a whole zero-length frame
    /// (`00 00 00 00 FF FF FF FF E3 B0 C4 42`, SHA-256's prefix for nothing) followed by more,
    /// its write torn just after those bytes. The asset is never read as a frame: b is cut and a
    /// opens.
    @Test func aFrameInsideAnAssetDoesNotChangeWhatRecoveryDecides() async throws {
        _ = try await open().save(Record(type: "T", id: RecordID("a")))
        let fake: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xE3, 0xB0, 0xC4, 0x42]
        let asset = Data(fake + Array(repeating: 0xAB, count: 256))
        let b = Record(type: "T", id: RecordID("b"), fields: ["blob": .assets([asset])])
        let (before, torn) = try await torn([b]) { frame in
            let at = try! #require(frame.firstRange(of: Data(fake)))
            return at.upperBound - frame.startIndex
        }
        let replayed = try LocalRecordDatabase.replay(torn)
        #expect(replayed.committed == before.count)
        #expect(replayed.examined == before.count - LocalRecordDatabase.slots)
        let reopened = try open()
        #expect(await reopened.current(RecordID("a")) != nil)
        #expect(await reopened.current(RecordID("b")) == nil)
        #expect(try Data(contentsOf: file) == before)
    }

    /// Codex's case for the cost: after a whole journal, a torn tail of N bytes beginning with a
    /// length that fails its complement, then through its first half a prefix every 12 bytes
    /// claiming N/2 bytes with the right complement and a wrong checksum, then nonzero bytes. The
    /// open reads none of it: what it hashes is counted, and it is the committed frames alone.
    @Test func aTailBuiltToCostTheScanCostsNothing() async throws {
        _ = try await open().save(Record(type: "T", id: RecordID("a")))
        let whole = try Data(contentsOf: file)
        let n = 64 << 10
        let be = { (v: UInt32) in [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var tail = Data(be(5) + be(5))
        while tail.count + 12 <= n / 2 { tail.append(contentsOf: be(UInt32(n / 2)) + be(~UInt32(n / 2)) + [1, 2, 3, 4]) }
        tail.append(Data(repeating: 0x5A, count: n - tail.count))
        let bytes = whole + tail
        let replayed = try LocalRecordDatabase.replay(bytes)
        #expect(replayed.examined == whole.count - LocalRecordDatabase.slots)
        #expect(replayed.examined <= bytes.count, "bounded by the file's length")
        try bytes.write(to: file)
        #expect(await (try open()).current(RecordID("a")) != nil)
        #expect(try Data(contentsOf: file) == whole)
    }

    /// What recovery reads is the committed frames, once: a count, not a time.
    @Test func recoveryHashesEachCommittedByteOnce() async throws {
        let db = try open()
        for i in 0..<20 { _ = try await db.save(Record(type: "T", id: RecordID("r\(i)"), fields: ["v": .string(String(repeating: "x", count: i * 50))])) }
        let bytes = try Data(contentsOf: file)
        #expect(try LocalRecordDatabase.replay(bytes).examined == bytes.count - LocalRecordDatabase.slots)
    }

    @Test func damageInsideTheCommittedLengthRefusesTheFile() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .string(String(repeating: "x", count: 64))]))
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        var bytes = try Data(contentsOf: file)
        let first = try LocalRecordDatabaseTests.frameStarts(bytes)[1]
        for i in (first + 20)..<(first + 40) { bytes[i] = 0xFF }
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == bytes, "nothing was cut")
    }

    /// A middle frame whose length is damaged is damage inside the committed length, refused with
    /// nothing cut, whatever it claims: past the end, inside the next frame, or exactly on the
    /// end of the file. The first is Codex's repro (b's length `0x7fffffff`, its complement
    /// `0x80000000`).
    @Test func aDamagedMiddleLengthIsRefusedAndCutsNothing() async throws {
        let db = try open()
        for name in ["a", "b", "c"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        let bytes = try Data(contentsOf: file)
        let b = try LocalRecordDatabaseTests.frameStarts(bytes)[2]
        let be = { (v: UInt32) in [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var damaged: [Data] = []
        var codex = bytes
        codex.replaceSubrange(b..<b + 8, with: [0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00])
        damaged.append(codex)
        for wrong in [UInt32(3), UInt32(bytes.count - b - LocalRecordDatabase.prefix)] {
            var moved = bytes
            moved.replaceSubrange(b..<b + 8, with: be(wrong) + be(~wrong))
            damaged.append(moved)
        }
        var high = bytes
        high[b] = 0x7F
        damaged.append(high)
        for case let moved in damaged {
            try moved.write(to: file)
            #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
            #expect(try Data(contentsOf: file) == moved, "nothing was cut")
        }
    }

    /// A compacted journal is its slots and one header frame holding the store. A flipped bit in
    /// the header is damage, refused with nothing cut rather than opened empty.
    @Test func aDamagedCompactedHeaderIsRefusedAndCutsNothing() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "Turn", id: RecordID("turn/p/1"), fields: ["t": .string("hi")]))
        var a = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 {
            a.fields["v"] = .int(Int64(v))
            a = try await db.save(a)
        }
        _ = try open()
        let bytes = try Data(contentsOf: file)
        let slots = LocalRecordDatabase.slots
        #expect(try LocalRecordDatabaseTests.frameStarts(bytes) == [slots], "compacted to one frame")
        for at in [bytes.count - 20, slots + 2, slots + 9, slots + LocalRecordDatabase.prefix + 3] {
            var flipped = bytes
            flipped[at] ^= 1
            try flipped.write(to: file)
            #expect(throws: LocalRecordDatabase.Failure.self, "a bit flipped at \(at)") { try open() }
            #expect(try Data(contentsOf: file) == flipped, "nothing was cut")
        }
        try bytes.write(to: file)
        #expect(await (try open()).current(RecordID("turn/p/1")) != nil)
    }

    /// A body inside the committed length that fails its checksum, its length intact, is damage.
    @Test func aCommittedBodyThatFailsItsChecksumIsDamage() async throws {
        let db = try open()
        for name in ["a", "b", "c"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        var bytes = try Data(contentsOf: file)
        let b = try LocalRecordDatabaseTests.frameStarts(bytes)[2]
        bytes[b + 12] ^= 0x01
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
    }

    /// A committed length past the end of the file is damage: what it committed is gone.
    @Test func aCommittedLengthPastTheEndIsDamage() async throws {
        let db = try open()
        for name in ["a", "b"] { _ = try await db.save(Record(type: "T", id: RecordID(name))) }
        let short = try Data(contentsOf: file).dropLast(3)
        try Data(short).write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == Data(short))
    }

    /// The newest slot unreadable (a slot write that tore, or rot) with its frame whole at the
    /// older slot's length: the frame is kept and committed again, so nothing answered is lost.
    @Test func anUnreadableNewestSlotKeepsTheFrameItCommitted() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        var bytes = try Data(contentsOf: file)
        let newest = try LocalRecordDatabase.replay(bytes).sequence
        let at = Int(LocalRecordDatabase.slotOffset(newest))
        bytes[at + 3] ^= 0x10
        try bytes.write(to: file)
        let replayed = try LocalRecordDatabase.replay(bytes)
        #expect(replayed.recommit && replayed.sequence == newest)
        let reopened = try open()
        #expect(await reopened.current(RecordID("b")) != nil)
        #expect(LocalRecordDatabase.readSlot(try Data(contentsOf: file), at / LocalRecordDatabase.slotSize) != nil,
                "the slot is written again")
        _ = try await reopened.save(Record(type: "T", id: RecordID("c")))
        let again = try open()
        for name in ["a", "b", "c"] { #expect(await again.current(RecordID(name)) != nil) }
    }

    /// The newest slot unreadable with nothing whole past the older one: the older slot's state.
    @Test func anUnreadableNewestSlotWithNoFrameOpensAtTheOlderSlot() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        var bytes = try Data(contentsOf: file)
        let newest = try LocalRecordDatabase.replay(bytes).sequence
        let committed = try LocalRecordDatabase.replay(bytes).committed
        // The slot write tore before its frame was whole: half the frame, then a bad slot.
        let frameStart = try LocalRecordDatabaseTests.frameStarts(bytes).last!
        bytes = bytes.prefix(frameStart + (committed - frameStart) / 2)
        bytes[Int(LocalRecordDatabase.slotOffset(newest)) + 1] ^= 0x01
        try bytes.write(to: file)
        let reopened = try open()
        #expect(await reopened.current(RecordID("a")) == nil)
        #expect(try Data(contentsOf: file).count == frameStart)
    }

    @Test func neitherSlotReadingIsDamage() async throws {
        _ = try await open().save(Record(type: "T", id: RecordID("a")))
        var bytes = try Data(contentsOf: file)
        bytes[1] ^= 1
        bytes[LocalRecordDatabase.slotSize + 1] ^= 1
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == bytes)
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

    /// Where each frame begins: the header's first, after the slots, then each save's.
    static func frameStarts(_ bytes: Data) throws -> [Int] {
        var out: [Int] = []
        var offset = LocalRecordDatabase.slots
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

    /// What the next writes do. A frame write can land `landing` of its bytes and fail; a slot
    /// write can land half and fail, or land and its synchronise fail; a barrier can fail.
    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var landing: Int?
        private var slotTears = false
        private var syncFails = false
        private var barrierFails = false
        private var cutFails = false
        private var replaceFails = false
        private(set) var replaces = 0
        func next(landing: Int? = nil, slotTears: Bool = false, syncFails: Bool = false,
                  barrierFails: Bool = false, cutFails: Bool = false, replaceFails: Bool = false) {
            lock.withLock {
                (self.landing, self.slotTears, self.syncFails) = (landing, slotTears, syncFails)
                (self.barrierFails, self.cutFails, self.replaceFails) = (barrierFails, cutFails, replaceFails)
            }
        }
        private func take<T>(_ key: ReferenceWritableKeyPath<Faults, T>, reset: T) -> T {
            lock.withLock { defer { self[keyPath: key] = reset }; return self[keyPath: key] }
        }
        var io: JournalIO {
            var io = JournalIO.system
            io.write = { [self] handle, offset, data in
                try handle.seek(toOffset: offset)
                if offset >= UInt64(LocalRecordDatabase.slots), let landing = take(\.landing, reset: nil) {
                    try handle.write(contentsOf: data.prefix(landing))
                    throw Fault()
                }
                if offset < UInt64(LocalRecordDatabase.slots), take(\.slotTears, reset: false) {
                    try handle.write(contentsOf: data.prefix(data.count / 2))
                    throw Fault()
                }
                try handle.write(contentsOf: data)
            }
            io.barrier = { [self] handle in
                if take(\.barrierFails, reset: false) { throw Fault() }
                try handle.synchronize()
            }
            io.synchronize = { [self] handle in
                if take(\.syncFails, reset: false) { throw Fault() }
                try handle.synchronize()
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

    /// Part of a frame reaches the file and the write fails, at every length short of the whole:
    /// the save is unavailable and not applied, the next save is written over it, and a reopen
    /// holds both whole saves and nothing of the failed one.
    @Test func aFrameThatFailsToLandIsWrittenOver() async throws {
        for landing in [1, 7, 12, 30] {
            try? FileManager.default.removeItem(at: file)
            let faults = Faults()
            let db = try LocalRecordDatabase(file: file, io: faults.io)
            _ = try await db.save(Record(type: "T", id: RecordID("a")))
            faults.next(landing: landing)
            await #expect(throws: RecordDatabaseError.self) { try await db.save(Record(type: "T", id: RecordID("lost"))) }
            #expect(await db.current(RecordID("lost")) == nil)
            _ = try await db.save(Record(type: "T", id: RecordID("after")))
            let reopened = try LocalRecordDatabase(file: file)
            #expect(await reopened.current(RecordID("a")) != nil, "\(landing)")
            #expect(await reopened.current(RecordID("after")) != nil, "\(landing)")
            #expect(await reopened.current(RecordID("lost")) == nil, "\(landing)")
        }
    }

    /// A barrier that fails: the save is unavailable and not applied, and nothing is committed.
    @Test func aBarrierThatFailsCommitsNothing() async throws {
        let faults = Faults()
        let db = try LocalRecordDatabase(file: file, io: faults.io)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        faults.next(barrierFails: true)
        await #expect(throws: RecordDatabaseError.self) { try await db.save(Record(type: "T", id: RecordID("lost"))) }
        _ = try await db.save(Record(type: "T", id: RecordID("after")))
        let reopened = try LocalRecordDatabase(file: file)
        #expect(await reopened.current(RecordID("lost")) == nil)
        #expect(await reopened.current(RecordID("after")) != nil)
    }

    /// A slot that tears or whose synchronise fails may or may not have committed its frame: the
    /// journal takes no more writes this launch, and the next open decides. Its frame was whole,
    /// so it decides the frame was committed, and every save that answered is there.
    @Test func aSlotThatFailsStopsEveryWriteAfterItAndTheOpenDecides() async throws {
        for tears in [true, false] {
            try? FileManager.default.removeItem(at: file)
            let faults = Faults()
            let db = try LocalRecordDatabase(file: file, io: faults.io)
            _ = try await db.save(Record(type: "T", id: RecordID("a")))
            faults.next(slotTears: tears, syncFails: !tears)
            await #expect(throws: RecordDatabaseError.self) { try await db.save(Record(type: "T", id: RecordID("maybe"))) }
            #expect(await db.current(RecordID("maybe")) == nil)
            do {
                _ = try await db.save(Record(type: "T", id: RecordID("refused")))
                Issue.record("a journal whose slot failed took another write")
            } catch RecordDatabaseError.rejected(let underlying) {
                #expect(LocalRecordDatabase.isJournalFailure(underlying))
            }
            let reopened = try LocalRecordDatabase(file: file)
            #expect(await reopened.current(RecordID("a")) != nil)
            #expect(await reopened.current(RecordID("maybe")) != nil, "the whole frame is kept")
            #expect(await reopened.current(RecordID("refused")) == nil)
            _ = try await reopened.save(Record(type: "T", id: RecordID("next")))
            let again = try LocalRecordDatabase(file: file)
            for name in ["a", "maybe", "next"] { #expect(await again.current(RecordID(name)) != nil) }
        }
    }

    /// Bytes past the committed length that the open cannot cut refuse the open.
    @Test func aTailThatCannotBeCutRefusesTheOpen() async throws {
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
