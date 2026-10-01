import Foundation
import Testing
import TopoCore
import TopoCoreTesting

/// A widget slot's record: one per slot, each write a compare-and-set on the tag of the read it
/// acted on, the newer revision winning within one runner, a clear a tombstone and never a delete.
@Suite struct SurfaceRecordTests {
    let db = InMemoryRecordDatabase()
    var records: SurfaceRecords { SurfaceRecords(database: db) }

    func surface(_ slot: String = "weather", revision: Int, images: [String: Data] = [:], runner: String = "phone-1") -> SurfaceRecord {
        SurfaceRecord(slot: slot, document: #"{"revision": \#(revision)}"#, revision: revision,
                      updated: Date(timeIntervalSince1970: TimeInterval(revision)), runner: runner, images: images)
    }

    /// A save over a fresh read of the slot.
    @discardableResult
    func put(_ surface: SurfaceRecord) async throws -> SurfaceRecords.Saved {
        try await records.save(surface, over: records.read(slot: surface.slot))
    }

    func clear(_ slot: String, runner: String = "phone-1") async throws {
        try await records.clear(slot: slot, runner: runner, at: Date(), over: records.read(slot: slot))
    }

    @Test func aSlotIsReplacedUnderItsTagAndNeverDuplicated() async throws {
        #expect(try await put(surface(revision: 1)) == .saved)
        #expect(try await put(surface(revision: 2)) == .saved)
        let all = try await db.records(ofType: SurfaceRecord.type)
        #expect(all.map(\.id) == [SurfaceRecord.id(slot: "weather")])
        #expect(all.first?.int("revision") == 2)
        let writes = await db.writes
        #expect(writes.count == 2)
        #expect(writes[1].changeTag != writes[0].changeTag)
    }

    @Test func anOlderRevisionNeverOverwritesANewer() async throws {
        try await put(surface(revision: 5))
        #expect(try await put(surface(revision: 4)) == .newerKept(revision: 5))
        #expect(await db.current(SurfaceRecord.id(slot: "weather"))?.int("revision") == 5)
        #expect(try await put(surface(revision: 5)) == .saved, "the same revision is a toggle's state, and replaces")
    }

    /// Revisions are each phone's own: another runner's record, at any revision, is replaced.
    @Test func anotherRunnersRecordIsReplacedWhateverItsRevision() async throws {
        try await put(surface(revision: 9, runner: "phone-0"))
        #expect(try await put(surface(revision: 1)) == .saved)
        let kept = try await records.fetch(slot: "weather")
        guard case .surface(let surface) = kept else { Issue.record("\(kept)"); return }
        #expect(surface.revision == 1)
        #expect(surface.runner == "phone-1")
    }

    /// A save or a clear acting on a read another writer has moved past is refused, and changes
    /// nothing: the record the other wrote stays.
    @Test func aWriteOverAStaleReadIsRefused() async throws {
        try await put(surface(revision: 1))
        let stale = try await records.read(slot: "weather")
        try await put(surface(revision: 2, runner: "phone-B"))
        await #expect(throws: RecordDatabaseError.self) { try await records.save(surface(revision: 3), over: stale) }
        await #expect(throws: RecordDatabaseError.self) {
            try await records.clear(slot: "weather", runner: "phone-1", at: Date(), over: stale)
        }
        let kept = try await records.fetch(slot: "weather")
        guard case .surface(let surface) = kept else { Issue.record("\(kept)"); return }
        #expect(surface.runner == "phone-B")
        #expect(surface.revision == 2)
    }

    /// A clear is a tombstone: the record stays, holding no document and no image, reads as gone,
    /// and a later save replaces it.
    @Test func aClearLeavesATombstone() async throws {
        try await put(surface("a", revision: 1, images: ["sky": Data([1])]))
        try await put(surface("b", revision: 1))
        try await clear("a")
        #expect(try await records.fetch(slot: "a") == .gone)
        let tombstone = try #require(await db.current(SurfaceRecord.id(slot: "a")))
        #expect(tombstone.string("document") == nil)
        #expect((tombstone.assets("images") ?? []).isEmpty)
        #expect(tombstone.int("cleared") == 1)
        guard case .surface = try await records.fetch(slot: "b") else { Issue.record("b went too"); return }
        let all = try await records.all()
        #expect(all.filter(\.holds).compactMap(\.slot) == ["b"])
        // Clearing a tombstone writes nothing; a save replaces it.
        let writes = await db.writes.count
        try await clear("a")
        #expect(await db.writes.count == writes)
        #expect(try await put(surface("a", revision: 2)) == .saved)
        guard case .surface = try await records.fetch(slot: "a") else { Issue.record("a not back"); return }
    }

    @Test func theImagesTravelAsAssets() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try await put(surface(revision: 1, images: ["photo": png, "icon": Data([9])]))
        let stored = try #require(await db.current(SurfaceRecord.id(slot: "weather")))
        #expect(stored.strings("imageNames") == ["icon", "photo"])
        #expect(stored.assets("images") == [Data([9]), png])
        let changes = try await records.changes(since: nil)
        #expect(changes.saved.first?.images == ["photo": png, "icon": Data([9])])
    }

    /// The feed names what was saved, what cannot be read, and what was cleared, a tombstone
    /// under the deleted, whether it is read from a token or from the start.
    @Test func theFeedNamesSlotsSavedAndCleared() async throws {
        try await put(surface("a", revision: 1))
        _ = try await db.save(Record(type: SurfaceRecord.type, id: SurfaceRecord.id(slot: "junk"), fields: ["slot": .string("junk")]))
        let first = try await records.changes(since: nil)
        #expect(first.saved.map(\.slot) == ["a"])
        #expect(first.unreadable == ["junk"])
        try await clear("a")
        let second = try await records.changes(since: first.token)
        #expect(second.deleted == ["a"])
        #expect(second.saved.isEmpty)
        let whole = try await records.changes(since: nil)
        #expect(whole.deleted == ["a"])
        #expect(whole.saved.isEmpty)
    }
}

/// Set once, from any task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
