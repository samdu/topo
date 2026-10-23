import Foundation
import TopoCore
#if DEBUG
import TopoCoreTesting
#endif

/// The record database the app's parts share — the harness's log, the role, the memory, the
/// widgets' slots, the viewer's transcript and lease — and how its zone is made. CloudKit's private
/// database, except in a debug build launched with `TOPO_DEBUG_STORE=memory`, which gets one
/// in-memory store for the life of the process, no zone to make and no push subscription to save:
/// nothing then waits on iCloud or the network, so a UI suite's first screen on a freshly booted
/// simulator is not as slow as CloudKit is (#434). Every part takes the same instance, so the role
/// a launch decides is the one the harness and the sweep read. The hub's unsigned build does the
/// same with `TOPO_STORE=memory`. `TOPO_DEBUG_STORE=stalled` gets a store that never answers and
/// a zone that is never made: CloudKit at its slowest, for seeing what the first screen does while
/// iCloud keeps it waiting (#436).
enum AppRecords {
    #if DEBUG
    static let storeVariable = "TOPO_DEBUG_STORE"
    private static let debugStore: (any ZoneDatabase)? = switch ProcessInfo.processInfo.environment[storeVariable] {
    case "memory": InMemoryRecordDatabase()
    case "stalled": StalledRecordDatabase()
    default: nil
    }
    private static var stalled: Bool { debugStore is StalledRecordDatabase }
    #endif

    static func database() -> any ZoneDatabase {
        #if DEBUG
        if let debugStore { return debugStore }
        #endif
        return TopoCloudKit.database()
    }

    /// True when the records are CloudKit's, so that a push subscription to its zone means
    /// something: the in-memory store has nothing to subscribe to, and a launch on it saves none.
    static var isCloudKit: Bool {
        #if DEBUG
        return debugStore == nil
        #else
        return true
        #endif
    }

    static let ensureZone: @Sendable () async throws -> Void = {
        #if DEBUG
        if stalled { try await StalledRecordDatabase.never() }
        if debugStore != nil { return }
        #endif
        try await TopoCloudKit.ensureZone()
    }
}

#if DEBUG
/// A record store whose every call waits until it is cancelled, and is never answered.
private struct StalledRecordDatabase: ZoneDatabase {
    static func never() async throws -> Never {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
    func save(_ records: [Record]) async throws -> [Record] { try await Self.never() }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await Self.never() }
    func query(_ query: RecordQuery) async throws -> [Record] { try await Self.never() }
    func records(ofType type: String) async throws -> [Record] { try await Self.never() }
    func delete(_ ids: [RecordID]) async throws { try await Self.never() }
    func changes(ofType type: String, since token: Data?) async throws -> RecordChanges { try await Self.never() }
}
#endif
