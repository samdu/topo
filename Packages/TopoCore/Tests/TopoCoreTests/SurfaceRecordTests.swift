import Foundation
import Testing
import TopoCore
import TopoCoreTesting

/// A widget slot's record: one per slot, replaced under its tag, the newer revision winning.
@Suite struct SurfaceRecordTests {
    let db = InMemoryRecordDatabase()
    var records: SurfaceRecords { SurfaceRecords(database: db) }

    func surface(_ slot: String = "weather", revision: Int, images: [String: Data] = [:], runner: String = "phone-1") -> SurfaceRecord {
        SurfaceRecord(slot: slot, document: #"{"revision": \#(revision)}"#, revision: revision,
                      updated: Date(timeIntervalSince1970: TimeInterval(revision)), runner: runner, images: images)
    }

    @Test func aSlotIsReplacedUnderItsTagAndNeverDuplicated() async throws {
        #expect(try await records.save(surface(revision: 1)) == .saved)
        #expect(try await records.save(surface(revision: 2)) == .saved)
        let all = try await db.records(ofType: SurfaceRecord.type)
        #expect(all.map(\.id) == [SurfaceRecord.id(slot: "weather")])
        #expect(all.first?.int("revision") == 2)
        let writes = await db.writes
        #expect(writes.count == 2)
        #expect(writes[1].changeTag != writes[0].changeTag)
    }

    @Test func anOlderRevisionNeverOverwritesANewer() async throws {
        try await records.save(surface(revision: 5))
        #expect(try await records.save(surface(revision: 4)) == .newerKept(revision: 5))
        #expect(await db.current(SurfaceRecord.id(slot: "weather"))?.int("revision") == 5)
        #expect(try await records.save(surface(revision: 5)) == .saved, "the same revision is a toggle's state, and replaces")
    }

    /// Revisions are each phone's own: another runner's record, at any revision, is replaced.
    @Test func anotherRunnersRecordIsReplacedWhateverItsRevision() async throws {
        try await records.save(surface(revision: 9, runner: "phone-0"))
        #expect(try await records.save(surface(revision: 1)) == .saved)
        let kept = try await records.fetch(slot: "weather")
        guard case .surface(let surface) = kept else { Issue.record("\(kept)"); return }
        #expect(surface.revision == 1)
        #expect(surface.runner == "phone-1")
    }

    /// A sign-out takes its own records and no one else's; the primary's sweep takes the rest.
    @Test func eachRunnerDeletesItsOwn() async throws {
        try await records.save(surface("a", revision: 1, runner: "phone-A"))
        try await records.save(surface("b", revision: 1, runner: "phone-B"))
        try await records.save(surface("c", revision: 1, runner: "phone-A"))
        try await records.deleteAll(of: "phone-A")
        #expect(try await db.records(ofType: SurfaceRecord.type).map(\.id) == [SurfaceRecord.id(slot: "b")])
        try await records.save(surface("d", revision: 1, runner: "phone-0"))
        try await records.deleteAll(except: "phone-B")
        #expect(try await db.records(ofType: SurfaceRecord.type).map(\.id) == [SurfaceRecord.id(slot: "b")])
    }

    /// Another writer lands between this save's fetch and its save: the stale tag is refused, and
    /// the save is judged again against what the refusal carries.
    @Test func aSaveRefusedForItsTagIsJudgedAgainstTheServersRevision() async throws {
        try await records.save(surface(revision: 1))
        let raced = Flag()
        let db = self.db
        await db.setBeforeSave { saving in
            guard saving.first?.int("revision") == 2, raced.set() else { return }
            var newer = await db.current(SurfaceRecord.id(slot: "weather"))!
            newer.fields["revision"] = .int(3)
            _ = try? await db.save(newer)
        }
        #expect(try await records.save(surface(revision: 2)) == .newerKept(revision: 3))
        #expect(await db.current(SurfaceRecord.id(slot: "weather"))?.int("revision") == 3)
    }

    @Test func aRaceWithAnOlderWriterStillSaves() async throws {
        try await records.save(surface(revision: 1))
        let raced = Flag()
        let db = self.db
        await db.setBeforeSave { saving in
            guard saving.first?.int("revision") == 3, raced.set() else { return }
            var other = await db.current(SurfaceRecord.id(slot: "weather"))!
            other.fields["revision"] = .int(2)
            _ = try? await db.save(other)
        }
        #expect(try await records.save(surface(revision: 3)) == .saved)
        #expect(await db.current(SurfaceRecord.id(slot: "weather"))?.int("revision") == 3)
    }

    @Test func aClearedSlotsRecordIsDeleted() async throws {
        try await records.save(surface("a", revision: 1))
        try await records.save(surface("b", revision: 1))
        try await records.delete(slot: "a")
        #expect(try await records.fetch(slot: "a") == .gone)
        guard case .surface = try await records.fetch(slot: "b") else { Issue.record("b went too"); return }
        try await records.deleteAll(of: "phone-1")
        #expect(try await db.records(ofType: SurfaceRecord.type).isEmpty)
    }

    @Test func theImagesTravelAsAssets() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try await records.save(surface(revision: 1, images: ["photo": png, "icon": Data([9])]))
        let stored = try #require(await db.current(SurfaceRecord.id(slot: "weather")))
        #expect(stored.strings("imageNames") == ["icon", "photo"])
        #expect(stored.assets("images") == [Data([9]), png])
        let changes = try await records.changes(since: nil)
        #expect(changes.saved.first?.images == ["photo": png, "icon": Data([9])])
    }

    @Test func theFeedNamesSlotsSavedAndDeleted() async throws {
        try await records.save(surface("a", revision: 1))
        _ = try await db.save(Record(type: SurfaceRecord.type, id: SurfaceRecord.id(slot: "junk"), fields: ["slot": .string("junk")]))
        let first = try await records.changes(since: nil)
        #expect(first.saved.map(\.slot) == ["a"])
        #expect(first.unreadable == ["junk"])
        try await records.delete(slot: "a")
        let second = try await records.changes(since: first.token)
        #expect(second.deleted == ["a"])
        #expect(second.saved.isEmpty)
    }
}

/// Set once, from any task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
