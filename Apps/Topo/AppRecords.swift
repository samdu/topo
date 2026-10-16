import Foundation
import TopoCore
#if DEBUG
import TopoCoreTesting
#endif

/// The record database the app's parts share — the harness's log, the role, the memory, the
/// widgets' slots — and how its zone is made. CloudKit's private database, except in a debug build
/// launched with `TOPO_DEBUG_STORE=memory`, which gets one in-memory store for the life of the
/// process and no zone to make: nothing then waits on iCloud or the network, so a UI suite's first
/// screen on a freshly booted simulator is not as slow as CloudKit is (#434). Every part takes the
/// same instance, so the role a launch decides is the one the harness and the sweep read. The
/// hub's unsigned build does the same with `TOPO_STORE=memory`.
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

    static let ensureZone: @Sendable () async throws -> Void = {
        #if DEBUG
        if memory != nil { return }
        #endif
        try await TopoCloudKit.ensureZone()
    }
}
