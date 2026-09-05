import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct TurnLogTests {
    let db = InMemoryRecordDatabase()
    var log: TurnLog { TurnLog(database: db) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func sequencesAreGaplessPerDeviceAndRecordsAreNamedByRef() async throws {
        let w = try await log.writer(for: phone)
        let a = try await w.append(.person, "hi", parents: [], at: t0)
        let b = try await w.append(.assistant, "hello", parents: [a.ref], at: t0 + 1)
        #expect(a.ref == .ref("phone", 1))
        #expect(b.ref == .ref("phone", 2))
        #expect(await db.current(Turn.recordID(for: b.ref)) != nil)
        #expect(Turn.recordID(for: b.ref).name == "turn/phone/2")

        let again = try await log.writer(for: phone)
        #expect(await again.nextRef == .ref("phone", 3))
    }

    @Test func turnRoundTripsThroughItsRecord() async throws {
        let w = try await log.writer(for: hub)
        let turn = try await w.append(.assistant, "x", parents: [.ref("phone", 1), .ref("watch", 4)], at: t0)
        let read = try await log.read()
        #expect(read[turn.ref] == turn)
        #expect(Turn(record: Record(type: Turn.recordType, id: RecordID("bad"))) == nil)
    }

    @Test func twoDevicesNeverOverwriteEachOther() async throws {
        let p = try await log.writer(for: phone)
        let h = try await log.writer(for: hub)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try await p.append(.person, "p\(i)", parents: [], at: t0) }
                group.addTask { _ = try await h.append(.assistant, "h\(i)", parents: [], at: t0) }
            }
            try await group.waitForAll()
        }
        let writes = await db.writes
        #expect(writes.filter { $0.type == Turn.recordType }.count == 40)
        #expect(Set(writes.map(\.id)).count == writes.count)
        let phoneTurns = try await log.read(device: phone, after: 0)
        #expect(phoneTurns.map(\.ref.sequence) == Array(1...20))
        #expect(try await log.read(device: hub, after: 17).map(\.ref.sequence) == [18, 19, 20])
    }

    @Test func twoWritersForOneDeviceTakeDistinctSequences() async throws {
        let first = try await log.writer(for: phone)
        let second = try await log.writer(for: phone)
        let a = try await first.append(.person, "a", parents: [], at: t0)
        let b = try await second.append(.person, "b", parents: [a.ref], at: t0)
        let c = try await first.append(.person, "c", parents: [b.ref], at: t0)
        #expect([a.ref, b.ref, c.ref] == [.ref("phone", 1), .ref("phone", 2), .ref("phone", 3)])
        #expect(await db.turnWrites == 3)
        #expect(await db.current(Turn.recordID(for: b.ref)).flatMap(Turn.init(record:))?.text == "b")
    }

    @Test func offlineBranchesReadAsAForkAndTheNextTurnJoinsThem() async throws {
        let p = try await log.writer(for: phone)
        let h = try await log.writer(for: hub)
        let root = try await p.append(.person, "start", parents: [], at: t0)
        let reply = try await h.append(.assistant, "ok", parents: [root.ref], at: t0 + 1)

        // Both devices continue from `reply` without seeing each other.
        let onPhone = try await p.append(.person, "phone says", parents: [reply.ref], at: t0 + 10)
        let onHub1 = try await h.append(.assistant, "hub says", parents: [reply.ref], at: t0 + 11)
        let onHub2 = try await h.append(.assistant, "hub says more", parents: [onHub1.ref], at: t0 + 12)

        let forked = try await log.read()
        #expect(forked.isForked)
        #expect(forked.heads == [onHub2.ref, onPhone.ref])
        #expect(forked.exclusive(to: onPhone.ref) == [onPhone])
        #expect(forked.exclusive(to: onHub2.ref) == [onHub1, onHub2])
        #expect(forked.ordered.map(\.text) == ["start", "ok", "phone says", "hub says", "hub says more"])

        let joined = try await h.append(.assistant, "carrying on", continuing: forked, at: t0 + 20)
        #expect(Set(joined.parents) == Set([onPhone.ref, onHub2.ref]))
        let after = try await log.read()
        #expect(!after.isForked)
        #expect(after.heads == [joined.ref])
        #expect(after.exclusive(to: joined.ref).count == after.turns.count)
    }

    @Test func emptyLogHasNoHeads() async throws {
        let t = try await log.read()
        #expect(t.isEmpty && t.heads.isEmpty && !t.isForked)
    }
}

@Suite struct IncompleteTranscriptTests {
    let db = InMemoryRecordDatabase()
    var log: TurnLog { TurnLog(database: db) }

    @Test func danglingParentIsReportedAndDoesNotTrap() async throws {
        let child = Turn(ref: .ref("phone", 2), parents: [.ref("phone", 1)], role: .person, text: "child", at: tA)
        let t = Transcript(turns: [child])
        #expect(t.heads == [child.ref])
        #expect(t.missing == [.ref("phone", 1)])
        #expect(!t.isComplete)
        #expect(t.ancestry(of: child.ref) == [child.ref])
        #expect(t.exclusive(to: child.ref).map(\.text) == ["child"])
    }

    @Test func malformedRecordIsReportedByTheRefItsNameCarries() async throws {
        var bad = turnRecord(device: "phone", seq: 1, parents: [])
        bad["role"] = .string("narrator")
        _ = try await db.save(bad)
        _ = try await db.save(turnRecord(device: "phone", seq: 2, parents: ["phone/1"]))
        _ = try await db.save(Record(type: Turn.recordType, id: RecordID("junk")))
        let t = try await log.read()
        #expect(t.turns.count == 1)
        #expect(t.missing == [.ref("phone", 1)])
        #expect(t.unreadable == [RecordID("junk")])
        #expect(t.exclusive(to: t.heads[0]).count == 1)
    }

    @Test func parentNotYetVisibleToTheQueryIsMissing() async throws {
        _ = try await db.save(turnRecord(device: "phone", seq: 2, parents: ["hub/1"]))
        let t = try await log.read()
        #expect(t.missing == [.ref("hub", 1), .ref("phone", 1)])
        #expect(t.exclusive(to: t.heads[0]).count == 1)
    }

    @Test func missingMiddleTurnIsNotAForkAndCannotBeContinuedFrom() async throws {
        _ = try await db.save(turnRecord(device: "phone", seq: 1, parents: []))
        var bad = turnRecord(device: "phone", seq: 2, parents: ["phone/1"])
        bad["role"] = .string("narrator")
        _ = try await db.save(bad)
        _ = try await db.save(turnRecord(device: "phone", seq: 3, parents: ["phone/2"]))

        let t = try await log.read()
        #expect(t.heads == [.ref("phone", 1), .ref("phone", 3)])
        #expect(!t.isComplete)
        let w = try await log.writer(for: hub)
        await #expect(throws: TurnLogError.self) {
            _ = try await w.append(.assistant, "carrying on", continuing: t, at: tA + 100)
        }
        #expect(await db.turnWrites == 3)
    }

    @Test func absentParentsFieldReadsAsARoot() async throws {
        var root = turnRecord(device: "phone", seq: 1, parents: [])
        root.fields.removeValue(forKey: "parents")
        _ = try await db.save(root)
        let t = try await log.read()
        #expect(t.isComplete)
        #expect(t[.ref("phone", 1)]?.parents == [])
    }

    @Test func nonPositiveSequencesDoNotTrapTheReader() async throws {
        let zero = Turn(ref: .ref("phone", 0), parents: [], role: .person, text: "zero", at: tA)
        let t = Transcript(turns: [zero])
        #expect(t.turns.count == 1)
        #expect(t.missing.isEmpty)

        _ = try await db.save(turnRecord(device: "phone", seq: -1, parents: []))
        _ = try await db.save(turnRecord(device: "phone", seq: 0, parents: []))
        _ = try await db.save(turnRecord(device: "phone", seq: 1, parents: []))
        let read = try await log.read()
        #expect(read.turns.count == 1)
        #expect(read.missing.isEmpty)
        #expect(Set(read.unreadable) == [RecordID("turn/phone/-1"), RecordID("turn/phone/0")])
        #expect(!read.isComplete)
        let w = try await log.writer(for: phone)
        #expect(await w.nextRef.sequence == 2)
    }

    @Test func oneUnreadableRecordKeepsBlockingContinuingUntilRepaired() async throws {
        _ = try await db.save(turnRecord(device: "phone", seq: 1, parents: []))
        var bad = turnRecord(device: "phone", seq: 2, parents: ["phone/1"])
        bad["role"] = .string("narrator")
        _ = try await db.save(bad)
        let w = try await log.writer(for: phone)
        _ = try await w.append(.person, "three", parents: [.ref("phone", 1)], at: tA + 1)
        var blocked = 0
        for _ in 0..<3 {
            let t = try await log.read()
            do { _ = try await w.append(.person, "next", continuing: t, at: tA + 2) } catch { blocked += 1 }
        }
        #expect(blocked == 3)
        // The plain append is the way on: name the heads by hand.
        let t = try await log.read()
        _ = try await w.append(.person, "next", parents: t.heads, at: tA + 2)
    }

    @Test func aQueryThatHidesTheNewestTurnIsIncomplete() async throws {
        let stale = StaleTailDatabase(inner: db)
        let fresh = TurnLog(database: db)
        let p = try await fresh.writer(for: phone)
        let h = try await fresh.writer(for: hub)
        let root = try await p.append(.person, "start", parents: [], at: tA)
        let reply = try await h.append(.assistant, "ok", parents: [root.ref], at: tA + 1)
        let more = try await p.append(.person, "more", parents: [reply.ref], at: tA + 2)
        let newest = try await h.append(.assistant, "and", parents: [more.ref], at: tA + 3)

        // The stale index shows only phone/1 and hub/1, which look complete
        // and unforked; the probe past each device's last seen turn finds
        // phone/2 and hub/2.
        let t = try await TurnLog(database: stale).read()
        #expect(Set(t.turns.keys) == [root.ref, reply.ref])
        #expect(t.missing == [more.ref, newest.ref])
        #expect(!t.isComplete)
        let w = try await TurnLog(database: stale).writer(for: watch)
        await #expect(throws: TurnLogError.self) {
            _ = try await w.append(.assistant, "fork", continuing: t, at: tA + 3)
        }
        #expect(await db.turnWrites == 4)

        // The same log through a caught-up index reads complete.
        let caughtUp = try await fresh.read()
        #expect(caughtUp.isComplete)
        #expect(caughtUp.heads == [newest.ref])
    }

    @Test func aRestartedWriterOnAFullyStaleIndexFindsItsOwnTurnsAndRefusesToFork() async throws {
        let fresh = TurnLog(database: db)
        let p = try await fresh.writer(for: phone)
        let h = try await fresh.writer(for: hub)
        let one = try await p.append(.person, "one", parents: [], at: tA)
        let two = try await h.append(.assistant, "two", parents: [one.ref], at: tA + 1)
        let three = try await p.append(.person, "three", parents: [two.ref], at: tA + 2)

        // Restart against an index that returns nothing.
        let blind = TurnLog(database: BlindQueryDatabase(inner: db))
        let again = try await blind.writer(for: phone)
        #expect(await again.nextRef == .ref("phone", 3))
        let empty = try await blind.read()
        #expect(empty.isEmpty && empty.isComplete)
        await #expect(throws: TurnLogError.self) {
            _ = try await again.append(.person, "four", continuing: empty, at: tA + 3)
        }
        #expect(await db.turnWrites == 3)

        // Against an index that hides only the newest turn of each device.
        let stale = TurnLog(database: StaleTailDatabase(inner: db))
        let partial = try await stale.read()
        #expect(partial.missing == [three.ref])      // hub/1 is hidden with nothing of the hub's to probe past
        let w = try await stale.writer(for: phone)
        #expect(await w.nextRef == .ref("phone", 3))
        await #expect(throws: TurnLogError.self) {
            _ = try await w.append(.person, "four", continuing: partial, at: tA + 3)
        }

        // A caught-up read carries on from the real head.
        let four = try await again.append(.person, "four", continuing: try await fresh.read(), at: tA + 3)
        #expect(four.ref == .ref("phone", 3))
        #expect(four.parents == [three.ref])
    }

    @Test func aWriterWillNotContinueFromAReadThatLacksItsOwnNewestTurn() async throws {
        let log = TurnLog(database: db)
        let p = try await log.writer(for: phone)
        _ = try await p.append(.person, "one", parents: [], at: tA)
        let before = try await log.read()
        _ = try await p.append(.person, "two", parents: before.heads, at: tA + 1)
        await #expect(throws: TurnLogError.self) {
            _ = try await p.append(.person, "three", continuing: before, at: tA + 2)
        }
        #expect(await db.turnWrites == 2)
        _ = try await p.append(.person, "three", continuing: try await log.read(), at: tA + 2)
        #expect(await db.turnWrites == 3)
    }

    @Test func exclusiveForTheOnlyHeadIsTheWholeLog() async throws {
        let root = Turn(ref: .ref("phone", 1), parents: [], role: .person, text: "root", at: tA)
        let child = Turn(ref: .ref("phone", 2), parents: [root.ref], role: .assistant, text: "child", at: tA + 1)
        let t = Transcript(turns: [root, child])
        #expect(t.exclusive(to: t.heads[0]).map(\.text) == ["root", "child"])
    }
}

@Suite struct TurnWriterRecoveryTests {
    @Test func coldQueryIndexIsCorrectedByIDBeforeTheFirstAppend() async throws {
        let inner = InMemoryRecordDatabase()
        for i in Int64(1)...5 { _ = try await inner.save(turnRecord(device: "phone", seq: i, parents: [])) }
        let w = try await TurnLog(database: BlindQueryDatabase(inner: inner)).writer(for: phone)
        #expect(await w.nextRef.sequence == 6)
        let t = try await w.append(.person, "found", parents: [], at: tA)
        #expect(t.ref.sequence == 6)
        #expect(await inner.turnWrites == 6)
    }

    @Test func manyTakenSequencesAreSkippedInOneAppend() async throws {
        let inner = InMemoryRecordDatabase()
        for i in Int64(1)...40 { _ = try await inner.save(turnRecord(device: "phone", seq: i, parents: [])) }
        let w = try await TurnLog(database: BlindQueryDatabase(inner: inner)).writer(for: phone)
        #expect(try await w.append(.person, "x", parents: [], at: tA).ref.sequence == 41)
    }

    @Test func lostAcknowledgementRetriedWithTheSameNonceDoesNotDuplicateTheTurn() async throws {
        let inner = InMemoryRecordDatabase()
        let log = TurnLog(database: FlakyOnceDatabase(inner: inner))
        let w = try await log.writer(for: phone)
        let nonce = UUID().uuidString
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        let retried = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        #expect(retried.ref.sequence == 1)
        #expect(retried.nonce == nonce)
        let turns = try await log.read(device: phone, after: 0)
        #expect(turns.map(\.text) == ["hello"])
        #expect(await w.nextRef.sequence == 2)
    }

    @Test func lostAcknowledgementRetriedAfterOtherAppendsDoesNotDuplicateTheTurn() async throws {
        let inner = InMemoryRecordDatabase()
        let log = TurnLog(database: FlakyOnceDatabase(inner: inner))
        let w = try await log.writer(for: phone)
        let nonce = UUID().uuidString
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        let b = try await w.append(.person, "meanwhile", parents: [], at: tA + 1)
        #expect(b.ref.sequence == 2)
        let retried = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        #expect(retried.ref.sequence == 1)
        #expect(try await log.read(device: phone, after: 0).map(\.text) == ["hello", "meanwhile"])
        #expect(await inner.turnWrites == 2)
        #expect(await w.nextRef.sequence == 3)
    }

    @Test func aRecoveryFetchThatFailsLeavesTheQuestionOpenForTheNextRetry() async throws {
        let inner = InMemoryRecordDatabase()
        let link = LossyLinkDatabase(inner: inner)
        let log = TurnLog(database: link)
        let w = try await log.writer(for: phone)
        let nonce = UUID().uuidString
        link.commitButDropNextSaveAck()
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        link.dropNextFetch()
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        let b = try await w.append(.person, "meanwhile", parents: [], at: tA + 1)
        #expect(b.ref.sequence == 2)
        let retried = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        #expect(retried.ref.sequence == 1)
        #expect(try await log.read(device: phone, after: 0).map(\.text) == ["hello", "meanwhile"])
        #expect(await inner.turnWrites == 2)
    }

    @Test func lostAcknowledgementRetriedAfterARelaunchDoesNotDuplicateTheTurn() async throws {
        let inner = InMemoryRecordDatabase()
        let log = TurnLog(database: FlakyOnceDatabase(inner: inner))
        let first = try await log.writer(for: phone)
        let nonce = UUID().uuidString
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await first.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        // The app relaunches: a fresh writer with no memory of the attempt.
        let relaunched = try await log.writer(for: phone)
        #expect(await relaunched.nextRef == .ref("phone", 2))
        for i in 0..<20 { _ = try await relaunched.append(.person, "later \(i)", parents: [], at: tA + 1) }
        let retried = try await relaunched.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        #expect(retried.ref == .ref("phone", 1))
        #expect(await inner.turnWrites == 21)
        #expect(await relaunched.nextRef == .ref("phone", 22))
    }

    @Test func turnRecordsAreOnlyEverWrittenOnce() async throws {
        let db = InMemoryRecordDatabase()
        let log = TurnLog(database: db)
        let w = try await log.writer(for: phone)
        for i in 0..<5 { _ = try await w.append(.person, "\(i)", parents: [], at: tA) }
        let writes = await db.writes
        #expect(writes.filter { $0.type == Turn.recordType }.count == 5)
        #expect(writes.filter { $0.type == "Append" }.count == 5)
        #expect(Set(writes.map(\.id)).count == writes.count)
    }

    @Test func aFailedAppendThatDidNotCommitIsWrittenOnRetry() async throws {
        let inner = InMemoryRecordDatabase()
        let log = TurnLog(database: DropOnceDatabase(inner: inner))
        let w = try await log.writer(for: phone)
        let nonce = UUID().uuidString
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        }
        let b = try await w.append(.person, "meanwhile", parents: [], at: tA + 1)
        #expect(b.ref.sequence == 1)
        let retried = try await w.append(.person, "hello", parents: [], at: tA, nonce: nonce)
        #expect(retried.ref.sequence == 2)
        #expect(try await log.read(device: phone, after: 0).map(\.text) == ["meanwhile", "hello"])
    }

    @Test func identicalContentFromAnotherWriterIsASecondTurn() async throws {
        for delta in [0.0, 0.0005, 0.002] {
            let db = InMemoryRecordDatabase()
            let log = TurnLog(database: db)
            let w1 = try await log.writer(for: phone)
            let w2 = try await log.writer(for: phone)
            let a = try await w1.append(.person, "ok", parents: [], at: tA)
            let b = try await w2.append(.person, "ok", parents: [], at: tA + delta)
            #expect(a.ref == .ref("phone", 1))
            #expect(b.ref == .ref("phone", 2))
            #expect(await db.turnWrites == 2)
        }
    }

    @Test func aRetryWithoutTheNonceIsASecondTurn() async throws {
        let inner = InMemoryRecordDatabase()
        let log = TurnLog(database: FlakyOnceDatabase(inner: inner))
        let w = try await log.writer(for: phone)
        _ = try? await w.append(.person, "hello", parents: [], at: tA)
        let again = try await w.append(.person, "hello", parents: [], at: tA)
        #expect(again.ref.sequence == 2)
    }

    @Test func malformedRecordAtTheTailIsSkippedAndReported() async throws {
        let db = InMemoryRecordDatabase()
        _ = try await db.save(turnRecord(device: "phone", seq: 1, parents: []))
        var bad = turnRecord(device: "phone", seq: 2, parents: ["phone/1"])
        bad["role"] = .string("narrator")
        _ = try await db.save(bad)
        let log = TurnLog(database: db)
        let w = try await log.writer(for: phone)
        let t = try await w.append(.person, "next", parents: [], at: tA)
        #expect(t.ref.sequence == 3)
        #expect(try await log.read().missing == [.ref("phone", 2)])
    }

    @Test func forcedSameSequenceCollisionNeverOverwrites() async throws {
        for _ in 0..<20 {
            let db = InMemoryRecordDatabase()
            let log = TurnLog(database: db)
            let w1 = try await log.writer(for: phone)
            let w2 = try await log.writer(for: phone)
            let barrier = Barrier(parties: 2)
            await db.setBeforeSave { _ in await barrier.arrive() }
            async let a: Turn = w1.append(.person, "a", parents: [], at: tA)
            async let b: Turn = w2.append(.person, "b", parents: [], at: tA)
            let both = try await [a, b]
            await db.setBeforeSave(nil)
            let writes = await db.writes
            #expect(Set(writes.map(\.id)).count == writes.count)
            #expect(Set(both.map(\.ref)).count == 2)
            #expect(try await log.read(device: phone, after: 0).map(\.text).sorted() == ["a", "b"])
        }
    }

    @Test func manyWritersForOneDeviceNeverOverwrite() async throws {
        for _ in 0..<10 {
            let db = InMemoryRecordDatabase()
            let log = TurnLog(database: db)
            var writers: [TurnWriter] = []
            for _ in 0..<4 { writers.append(try await log.writer(for: phone)) }
            var wrote = 0
            await withTaskGroup(of: Bool.self) { g in
                for (i, w) in writers.enumerated() {
                    for j in 0..<3 {
                        g.addTask { (try? await w.append(.person, "w\(i)-\(j)", parents: [], at: tA)) != nil }
                    }
                }
                for await ok in g where ok { wrote += 1 }
            }
            let writes = await db.writes
            #expect(Set(writes.map(\.id)).count == writes.count)
            #expect(writes.filter { $0.type == Turn.recordType }.count == wrote)
            #expect(wrote == 12)
        }
    }
}
