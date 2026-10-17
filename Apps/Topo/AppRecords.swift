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
/// same with `TOPO_STORE=memory`.
enum AppRecords {
    #if DEBUG
    static let storeVariable = "TOPO_DEBUG_STORE"
    private static let memory: InMemoryRecordDatabase? =
        ProcessInfo.processInfo.environment[storeVariable] == "memory" ? InMemoryRecordDatabase() : nil
    #endif

    static func database() -> any ZoneDatabase {
        #if DEBUG
        if let memory { return memory }
        #endif
        return TopoCloudKit.database()
    }

    /// True when the records are CloudKit's, so that a push subscription to its zone means
    /// something: the in-memory store has nothing to subscribe to, and a launch on it saves none.
    static var isCloudKit: Bool {
        #if DEBUG
        return memory == nil
        #else
        return true
        #endif
    }

    static let ensureZone: @Sendable () async throws -> Void = {
        #if DEBUG
        if memory != nil { return }
        #endif
        try await TopoCloudKit.ensureZone()
    }
}
