import TopoCore
import TopoCoreTesting

/// The database that counts the reads of each type's change feed, which over CloudKit are the
/// round trips an idle pass costs; everything else goes to the one it wraps.
actor CountingDatabase: RecordDatabase {
    let wrapped: any RecordDatabase
    private var feedReads: [String: Int] = [:]

    init(_ wrapped: any RecordDatabase) { self.wrapped = wrapped }

    func reads(ofType type: String) -> Int { feedReads[type] ?? 0 }

    func save(_ records: [Record]) async throws -> [Record] { try await wrapped.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }

    func records(ofType type: String) async throws -> [Record] {
        feedReads[type, default: 0] += 1
        return try await wrapped.records(ofType: type)
    }
}
