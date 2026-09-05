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
        #expect(writes.count == 40)
        #expect(Set(writes.map(\.id)).count == 40)
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
        #expect(await db.writes.count == 3)
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
        #expect(await db.writes.count == 3)
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

    @Test func exclusiveForTheOnlyHeadIsTheWholeLog() async throws {
        let root = Turn(ref: .ref("phone", 1), parents: [], role: .person, text: "root", at: tA)
        let child = Turn(ref: .ref("phone", 2), parents: [root.ref], role: .assistant, text: "child", at: tA + 1)
        let t = Transcript(turns: [root, child])
        #expect(t.exclusive(to: t.heads[0]).map(\.text) == ["root", "child"])
    }
}

@Suite struct TurnWriterRecoveryTests {
    @Test func coldQueryIndexCostsOneCollisionNotTheTurn() async throws {
        let inner = InMemoryRecordDatabase()
        for i in Int64(1)...5 { _ = try await inner.save(turnRecord(device: "phone", seq: i, parents: [])) }
        let w = try await TurnLog(database: BlindQueryDatabase(inner: inner)).writer(for: phone)
        #expect(await w.nextRef.sequence == 1)
        let t = try await w.append(.person, "found", parents: [], at: tA)
        #expect(t.ref.sequence == 6)
        #expect(await inner.writes.count == 6)
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
            #expect(await db.writes.count == 2)
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
            #expect(writes.count == wrote)
            #expect(wrote == 12)
        }
    }
}
