import Foundation
import Testing
import TopoCore

/// A change feed held in memory: an append-only list of saves and deletions, answered a page at
/// a time from a token that is the position in it.
private actor Feed {
    enum Change { case saved(Record), deleted(RecordID) }
    private var changes: [Change] = []
    private var epoch = 0
    private(set) var pulls: [Int?] = []
    var pageSize = 2
    var failAt: Int?

    func save(_ type: String, _ name: String, v: Int64 = 1) {
        changes.append(.saved(Record(type: type, id: RecordID(name), fields: ["v": .int(v)])))
    }
    func delete(_ name: String) { changes.append(.deleted(RecordID(name))) }
    func expire() { epoch += 1 }
    func set(failAt: Int?) { self.failAt = failAt }

    func page(since token: Data?) throws -> ZoneFeedPage {
        var start = 0
        if let token {
            let parts = String(decoding: token, as: UTF8.self).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] == epoch else { throw RecordChangesError.tokenExpired }
            start = parts[1]
        }
        pulls.append(token == nil ? nil : start)
        if let failAt, start >= failAt { throw RecordDatabaseError.unavailable(underlying: CancellationError()) }
        let end = min(start + pageSize, changes.count)
        var changed: [Record] = []
        var deleted: [RecordID] = []
        for change in changes[start..<end] {
            switch change {
            case .saved(let record): changed.append(record)
            case .deleted(let id): deleted.append(id)
            }
        }
        return ZoneFeedPage(changed: changed, deleted: deleted, token: Data("\(epoch):\(end)".utf8),
                            moreComing: end < changes.count)
    }
}

@Suite struct ZoneMirrorTests {
    private let feed = Feed()
    private var mirror: ZoneMirror { ZoneMirror { [feed] in try await feed.page(since: $0) } }

    @Test func theFirstReadWalksTheFeedAndKeepsToTheType() async throws {
        await feed.save("Turn", "b"); await feed.save("Note", "n"); await feed.save("Turn", "a")
        let read = try await mirror.records(ofType: "Turn")
        #expect(read.map(\.id.name) == ["a", "b"])
    }

    @Test func aLaterReadAsksOnlyFromWhereTheLastStopped() async throws {
        let mirror = mirror
        for name in ["a", "b", "c", "d", "e"] { await feed.save("Turn", name) }
        _ = try await mirror.records(ofType: "Turn")
        #expect(await feed.pulls == [nil, 2, 4])
        await feed.save("Turn", "f")
        let read = try await mirror.records(ofType: "Turn")
        #expect(read.map(\.id.name) == ["a", "b", "c", "d", "e", "f"])
        #expect(await feed.pulls == [nil, 2, 4, 5])
    }

    @Test func aTypeNotAskedForBeforeIsAnsweredFromTheSameWalk() async throws {
        let mirror = mirror
        await feed.save("Turn", "a"); await feed.save("Note", "n")
        _ = try await mirror.records(ofType: "Turn")
        let notes = try await mirror.records(ofType: "Note")
        #expect(notes.map(\.id.name) == ["n"])
        #expect(await feed.pulls == [nil, 2])
    }

    @Test func aSaveOverARecordAndADeletionAreFoldedIn() async throws {
        let mirror = mirror
        await feed.save("Turn", "a"); await feed.save("Turn", "b")
        _ = try await mirror.records(ofType: "Turn")
        await feed.save("Turn", "a", v: 2); await feed.delete("b")
        let read = try await mirror.records(ofType: "Turn")
        #expect(read.map(\.id.name) == ["a"])
        #expect(read.first?.int("v") == 2)
    }

    @Test func anExpiredTokenIsAWalkFromTheBeginning() async throws {
        let mirror = mirror
        await feed.save("Turn", "a"); await feed.save("Turn", "b")
        _ = try await mirror.records(ofType: "Turn")
        await feed.delete("b"); await feed.expire()
        let read = try await mirror.records(ofType: "Turn")
        #expect(read.map(\.id.name) == ["a"])
    }

    @Test func aReadThatFailsPartwayIsCarriedOnFromByTheNext() async throws {
        let mirror = mirror
        for name in ["a", "b", "c", "d"] { await feed.save("Turn", name) }
        await feed.set(failAt: 2)
        await #expect(throws: RecordDatabaseError.self) { try await mirror.records(ofType: "Turn") }
        await feed.set(failAt: nil)
        let read = try await mirror.records(ofType: "Turn")
        #expect(read.map(\.id.name) == ["a", "b", "c", "d"])
        #expect(await feed.pulls == [nil, 2, 2])
    }

    @Test func readsAtOnceEachSeeWhatWasSavedBeforeTheyBegan() async throws {
        let mirror = mirror
        for name in ["a", "b", "c"] { await feed.save("Turn", name) }
        async let first = mirror.records(ofType: "Turn")
        async let second = mirror.records(ofType: "Turn")
        let (one, two) = try await (first, second)
        #expect(one.count == 3 && two.count == 3)
        #expect(await feed.pulls.filter { $0 == nil }.count == 1)
    }
}
