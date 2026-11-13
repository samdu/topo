import TopoCore
import TopoCoreTesting

/// The database that counts the reads of each type's change feed, which over CloudKit are the
/// round trips an idle pass costs; everything else goes to the one it wraps.
actor CountingDatabase: ForwardingDatabase {
    let wrapped: any RecordDatabase
    nonisolated var base: any RecordDatabase { wrapped }
    private var feedReads: [String: Int] = [:]

    init(_ wrapped: any RecordDatabase) { self.wrapped = wrapped }

    func reads(ofType type: String) -> Int { feedReads[type] ?? 0 }

    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        feedReads[type, default: 0] += 1
        return try await base.records(ofType: type)
    }
}
