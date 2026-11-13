import Foundation
import TopoCore

/// A test double that wraps another database and changes some of what reaches it: it forwards
/// every call to `base`, the bound of `answering(within:)` included, and a wrapper writes only the
/// hooks it changes.
///
/// `RecordDatabase`'s own `answering(within:)` answers with the database itself, which is right for
/// a store with no link and wrong for a wrapper: a wrapper over a store that gives a request up at
/// its bound (`HoldingDatabase`, CloudKit) would hand the lease an unbounded view. Here the bounded
/// view is the same wrapper's hooks over `base.answering(within:)`, so what the wrapper does holds
/// in the view, and the bound reaches the store under it. What a hook does itself before or after
/// the call it forwards (a hold, a count) is not under the bound; a hold that should run out is
/// `HoldingDatabase`'s.
///
/// Every call a hook makes goes to the database it is handed, never to `base` or an inner store
/// held by name: in the bounded view that database is the bounded one. A wrapper declares the
/// hooks, not `save(_:)` and its siblings, which would answer the unbounded calls and leave the
/// bounded view the defaults.
public protocol ForwardingDatabase: RecordDatabase {
    /// The database every call goes to.
    var base: any RecordDatabase { get }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record]
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record]
    func query(_ query: RecordQuery, through base: any RecordDatabase) async throws -> [Record]
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record]
}

extension ForwardingDatabase {
    public func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        try await base.save(records)
    }
    public func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        try await base.fetch(ids)
    }
    public func query(_ query: RecordQuery, through base: any RecordDatabase) async throws -> [Record] {
        try await base.query(query)
    }
    public func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        try await base.records(ofType: type)
    }

    public func save(_ records: [Record]) async throws -> [Record] { try await save(records, through: base) }
    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await fetch(ids, through: base) }
    public func query(_ query: RecordQuery) async throws -> [Record] { try await self.query(query, through: base) }
    public func records(ofType type: String) async throws -> [Record] { try await records(ofType: type, through: base) }

    public func answering(within seconds: TimeInterval) -> any RecordDatabase {
        ForwardingView(wrapper: self, base: base.answering(within: seconds))
    }
}

/// A wrapper's bounded view: its hooks over its base's bounded view.
private struct ForwardingView<Wrapper: ForwardingDatabase>: RecordDatabase {
    let wrapper: Wrapper
    let base: any RecordDatabase

    func save(_ records: [Record]) async throws -> [Record] { try await wrapper.save(records, through: base) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapper.fetch(ids, through: base) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapper.query(query, through: base) }
    func records(ofType type: String) async throws -> [Record] { try await wrapper.records(ofType: type, through: base) }
    func answering(within seconds: TimeInterval) -> any RecordDatabase { wrapper.answering(within: seconds) }
}
