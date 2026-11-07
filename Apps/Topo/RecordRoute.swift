@preconcurrency import CloudKit
import Foundation
import os
import TopoCore

/// Where this install's records live: CloudKit's private database, or, on a phone with no
/// iCloud account, a journal on the phone (`LocalRecordDatabase`).
///
/// The route is decided once per install and the journal's file is what records it: the route
/// is local exactly when the file exists. It is made at the install's first decision alone —
/// no role kept yet (`RoleSelector.hasDecided`) and no file — and only when CloudKit says this
/// phone has no iCloud account (`CKAccountStatus.noAccount`). An account that is there in any
/// state (`available`, `restricted`, `temporarilyUnavailable`) is CloudKit, as is any install
/// that has decided its role without a file: a phone that has been on iCloud and is signed out
/// of it later stays on iCloud, whose refusal says so, rather than starting a second log on the
/// phone. A status CloudKit cannot give (`couldNotDetermine`, a throw) decides nothing: it is
/// asked again, backing off, and every call waits for an answer rather than failing for want of
/// one, so the first reads' bound (`RoleSelector.firstReadBound`) runs out on it as on a store
/// that has not answered, and nothing is claimed or kept over a store nobody chose.
///
/// The route is never switched while the app runs.
actor RecordRoute {
    enum Store: Equatable, Sendable {
        case cloud, local
    }

    private let file: URL
    private let decided: @Sendable () -> Bool
    private let account: @Sendable () async throws -> CKAccountStatus
    private let pause: @Sendable (Int) async -> Void
    private var resolving: Task<Resolved, any Error>?
    private var resolved: Resolved?

    /// The route decided: CloudKit, or the journal, opened.
    enum Resolved: Sendable {
        case cloud
        case local(LocalRecordDatabase)

        var store: Store {
            if case .local = self { return .local }
            return .cloud
        }
    }

    /// - Parameter pause: the wait before asking the account again, after that many asks that
    ///   decided nothing.
    init(file: URL, decided: @escaping @Sendable () -> Bool,
         account: @escaping @Sendable () async throws -> CKAccountStatus,
         pause: @escaping @Sendable (Int) async -> Void = { asked in
             try? await Task.sleep(for: .seconds(min(pow(2, Double(min(asked, 5))), 30)))
         }) {
        self.file = file
        self.decided = decided
        self.account = account
        self.pause = pause
    }

    /// The route, once it is decided.
    func route() async throws -> Resolved {
        try await resolve()
    }

    func store() async throws -> Store {
        try await resolve().store
    }

    /// The route if it has been decided, without waiting for it.
    var decidedStore: Store? { resolved?.store }

    private func resolve() async throws -> Resolved {
        if let resolved { return resolved }
        let task = resolving ?? Task { [file, decided, account, pause] in
            try await Self.decide(file: file, decided: decided, account: account, pause: pause)
        }
        resolving = task
        do {
            let answer = try await task.value
            resolved = answer
            return answer
        } catch {
            // A journal that would not open is asked again by the next call, never taken for
            // the cloud: its records are this phone's only copy.
            resolving = nil
            throw error
        }
    }

    private static func decide(file: URL, decided: @Sendable () -> Bool,
                               account: @Sendable () async throws -> CKAccountStatus,
                               pause: @Sendable (Int) async -> Void) async throws -> Resolved {
        if FileManager.default.fileExists(atPath: file.path) { return .local(try open(file)) }
        if decided() { return .cloud }
        var asked = 0
        while true {
            switch try? await account() {
            case .noAccount?:
                TopoLog(.cloud).notice("records: no iCloud account at the first decision; kept on this phone")
                return .local(try open(file))
            case .available?, .restricted?, .temporarilyUnavailable?:
                return .cloud
            default:
                asked += 1
                TopoLog(.cloud).notice("records: the iCloud account could not be told (ask \(asked)); asking again")
                await pause(asked)
            }
        }
    }

    private static func open(_ file: URL) throws -> LocalRecordDatabase {
        do {
            return try LocalRecordDatabase(file: file)
        } catch {
            TopoLog(.cloud).error("records: the journal on this phone would not open: \(String(describing: type(of: error)))")
            throw RecordDatabaseError.rejected(underlying: error)
        }
    }

    /// The journal of a phone with no iCloud account: in Application Support, which device
    /// backups keep, because on that phone it is the person's only copy.
    static var standardFile: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? URL.applicationSupportDirectory
        return support.appending(path: "Records", directoryHint: .isDirectory).appending(path: "records.journal")
    }
}

/// The records as one `ZoneDatabase` whose every call waits for the route and goes to the store
/// it names, so the parts that take the database at launch, before the route is known, need no
/// change. Each keeps its own CloudKit database, as each part had before there was a route (one
/// holds the records it fetched to save over), and the journal is the route's one instance.
struct RoutedRecordDatabase: ZoneDatabase {
    let route: RecordRoute
    let cloud: any ZoneDatabase
    /// The bound a caller asked for (`answering(within:)`), applied to the wait for the route as
    /// well as to the request the store makes.
    var bound: TimeInterval?

    private func zone() async throws -> any ZoneDatabase {
        let resolved: RecordRoute.Resolved
        if let bound {
            resolved = try await Self.within(bound) { try await route.route() }
        } else {
            resolved = try await route.route()
        }
        switch resolved {
        case .cloud: return cloud
        case .local(let local): return local
        }
    }

    private func store() async throws -> any RecordDatabase {
        let database = try await zone()
        guard let bound else { return database }
        return database.answering(within: bound)
    }

    func save(_ records: [Record]) async throws -> [Record] { try await store().save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await store().fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await store().query(query) }
    func records(ofType type: String) async throws -> [Record] { try await store().records(ofType: type) }
    func delete(_ ids: [RecordID]) async throws { try await zone().delete(ids) }
    func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        try await zone().changes(ofType: type, since: token)
    }

    func answering(within seconds: TimeInterval) -> any RecordDatabase {
        RoutedRecordDatabase(route: route, cloud: cloud, bound: seconds)
    }

    /// The route within `seconds`, or `unavailable`, as a bounded request that ran out is. The
    /// wait for the route is not cancellable, so it is not waited for past the bound: its answer,
    /// when it comes, goes nowhere.
    private static func within(_ seconds: TimeInterval,
                               _ work: @escaping @Sendable () async throws -> RecordRoute.Resolved) async throws -> RecordRoute.Resolved {
        let answered = OSAllocatedUnfairLock(initialState: false)
        var tasks: [Task<Void, Never>] = []
        defer { tasks.forEach { $0.cancel() } }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordRoute.Resolved, any Error>) in
            let answer: @Sendable (Result<RecordRoute.Resolved, any Error>) -> Void = { result in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            tasks.append(Task {
                do { answer(.success(try await work())) } catch { answer(.failure(error)) }
            })
            tasks.append(Task {
                guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                answer(.failure(RecordDatabaseError.unavailable(underlying: RouteNotDecided())))
            })
        }
    }

    struct RouteNotDecided: Error {}
}
