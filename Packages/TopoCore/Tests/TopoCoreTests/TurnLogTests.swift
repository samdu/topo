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
