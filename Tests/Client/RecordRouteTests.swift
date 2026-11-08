import CloudKit
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

/// Where a phone's records go: the journal only for an install that had no iCloud account at
/// its first decision, CloudKit for everything else, and nothing decided from a status CloudKit
/// could not give.
final class RecordRouteTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appending(path: "records.journal") }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: "route-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func route(decided: Bool = false, _ statuses: [Result<CKAccountStatus, Error>],
                       asked: Asked = Asked()) -> RecordRoute {
        RecordRoute(file: file, decided: { decided }, account: {
            try await asked.next(statuses).get()
        }, pause: { _ in await Task.yield() })
    }

    actor Asked {
        var count = 0
        func next(_ statuses: [Result<CKAccountStatus, Error>]) -> Result<CKAccountStatus, Error> {
            defer { count += 1 }
            return statuses[min(count, statuses.count - 1)]
        }
    }

    struct Thrown: Error {}

    // Review Focus 1: only `.noAccount` at the first decision puts the records on the phone.
    func testOnlyNoAccountGoesLocal() async throws {
        let none = route([.success(.noAccount)])
        let store = try await none.store()
        XCTAssertEqual(store, .local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the file is the route")
        try FileManager.default.removeItem(at: folder)

        for status in [CKAccountStatus.available, .restricted, .temporarilyUnavailable] {
            let other = route([.success(status)])
            let store = try await other.store()
            XCTAssertEqual(store, .cloud, "\(status)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(status) makes no journal")
        }
    }

    /// A status CloudKit could not give, or a throw, decides nothing: it is asked again, and the
    /// route waits rather than taking either store.
    func testAnUndeterminedAccountDecidesNothingAndIsAskedAgain() async throws {
        for undecided in [Result<CKAccountStatus, Error>.success(.couldNotDetermine), .failure(Thrown())] {
            try? FileManager.default.removeItem(at: folder)
            let asked = Asked()
            let r = route([undecided, undecided, .success(.noAccount)], asked: asked)
            let store = try await r.store()
            XCTAssertEqual(store, .local)
            let count = await asked.count
            XCTAssertEqual(count, 3, "asked until it had an answer")
        }
    }

    /// A route that cannot be told waits; a bounded caller is told `unavailable`, as for a store
    /// that has not answered, never an answer from a store nobody chose.
    func testABoundedCallOnARouteNotDecidedRunsOutAsUnavailable() async throws {
        let r = RecordRoute(file: file, decided: { false }, account: { .couldNotDetermine },
                            pause: { _ in try? await Task.sleep(for: .seconds(1)) })
        let cloud = InMemoryRecordDatabase()
        let db = RoutedRecordDatabase(route: r, cloud: cloud).answering(within: 0.2)
        do {
            _ = try await db.fetch(Lease.recordID)
            XCTFail("a route not decided answered")
        } catch RecordDatabaseError.unavailable {
        }
        let decided = await r.decidedStore
        XCTAssertNil(decided)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// One deadline for the wait and the request: a route that takes most of the bound leaves
    /// the store only what is left. Codex's sequence, scaled: the account answering in 0.3 s of
    /// a 1 s bound leaves a fetch that takes 0.9 s too little, which the whole bound would not.
    func testTheStoreHasOnlyWhatTheRouteLeftOfTheBound() async throws {
        let r = RecordRoute(file: file, decided: { false }, account: {
            try await Task.sleep(for: .milliseconds(300))
            return .available
        }, pause: { _ in await Task.yield() })
        let cloud = Slow(takes: 0.9)
        let db = RoutedRecordDatabase(route: r, cloud: cloud).answering(within: 1.0)
        do {
            _ = try await db.fetch(Lease.recordID)
            XCTFail("a fetch answered past the call's bound")
        } catch RecordDatabaseError.unavailable {}
        let asked = try XCTUnwrap(cloud.bounds.first)
        XCTAssertLessThanOrEqual(asked, 0.75, "the store was given \(asked) s of a 1 s bound after a 0.3 s route")
    }

    /// On iOS the journal asks for protection until first unlock on its folder, at its creation
    /// and at a compaction, and nothing excludes it from backups.
    func testTheJournalIsProtectedUntilFirstUnlockAndBackedUp() async throws {
        let asked = NSLock()
        nonisolated(unsafe) var writes: [Data.WritingOptions] = []
        nonisolated(unsafe) var folders: [FileProtectionType?] = []
        var io = JournalIO.system
        io.replace = { data, url, options in
            asked.withLock { writes.append(options) }
            try data.write(to: url, options: options)
        }
        io.makeFolder = { url, attributes in
            asked.withLock { folders.append(attributes[.protectionKey] as? FileProtectionType) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        }
        let db = try LocalRecordDatabase(file: file, io: io)
        var record = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 {
            record.fields["v"] = .int(Int64(v))
            record = try await db.save(record)
        }
        _ = try LocalRecordDatabase(file: file, io: io)
        let (w, f) = asked.withLock { (writes, folders) }
        XCTAssertEqual(w.count, 2, "the creation and the compaction")
        XCTAssertTrue(w.allSatisfy { $0.contains(.atomic) && $0.contains(.completeFileProtectionUntilFirstUserAuthentication) })
        XCTAssertEqual(f, [.completeUntilFirstUserAuthentication, .completeUntilFirstUserAuthentication])
        for url in [file, folder!] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        }
        let kept = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
        print("[records-protection] read back on this device: \(String(describing: kept))")
    }

    /// A store whose requests take `takes` seconds, and which runs out as CloudKit's bounded
    /// requests do when given less.
    final class Slow: ZoneDatabase, @unchecked Sendable {
        let takes: TimeInterval
        private let lock = NSLock()
        private var asked: [TimeInterval] = []
        init(takes: TimeInterval) { self.takes = takes }
        var bounds: [TimeInterval] { lock.withLock { asked } }

        struct Bounded: RecordDatabase {
            let takes: TimeInterval
            let seconds: TimeInterval
            private func wait() async throws {
                try await Task.sleep(for: .seconds(min(takes, seconds)))
                if seconds < takes { throw RecordDatabaseError.unavailable(underlying: Thrown()) }
            }
            func save(_ records: [Record]) async throws -> [Record] { try await wait(); return records }
            func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wait(); return [:] }
            func query(_ query: RecordQuery) async throws -> [Record] { try await wait(); return [] }
            func records(ofType type: String) async throws -> [Record] { try await wait(); return [] }
            func answering(within seconds: TimeInterval) -> any RecordDatabase {
                Bounded(takes: takes, seconds: min(seconds, self.seconds))
            }
        }

        private var unbounded: Bounded { Bounded(takes: takes, seconds: .infinity) }
        func save(_ records: [Record]) async throws -> [Record] { try await unbounded.save(records) }
        func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await unbounded.fetch(ids) }
        func query(_ query: RecordQuery) async throws -> [Record] { try await unbounded.query(query) }
        func records(ofType type: String) async throws -> [Record] { try await unbounded.records(ofType: type) }
        func delete(_ ids: [RecordID]) async throws {}
        func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
            try await InMemoryRecordDatabase().changes(ofType: type, since: token)
        }
        func answering(within seconds: TimeInterval) -> any RecordDatabase {
            lock.withLock { asked.append(seconds) }
            return Bounded(takes: takes, seconds: seconds)
        }
    }

    // Review Focus 2: a phone that has decided its role on CloudKit stays there when its
    // account goes away, and is never asked.
    func testDecidedCloudStaysCloud() async throws {
        let asked = Asked()
        let r = route(decided: true, [.success(.noAccount)], asked: asked)
        let store = try await r.store()
        XCTAssertEqual(store, .cloud)
        let count = await asked.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A role kept while the account was being asked is read again at the answer: no journal.
    func testARoleKeptWhileTheAccountIsAskedStaysCloud() async throws {
        let flag = Flag()
        let r = RecordRoute(file: file, decided: { flag.value }, account: {
            flag.value = true
            return .noAccount
        })
        let store = try await r.store()
        XCTAssertEqual(store, .cloud)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// An install whose journal exists is on the phone whatever the account says now: the move
    /// into iCloud is its own step, never a switch at launch.
    func testAJournalKeepsTheRouteLocal() async throws {
        _ = try LocalRecordDatabase(file: file)
        let r = route(decided: true, [.success(.available)])
        let store = try await r.store()
        XCTAssertEqual(store, .local)
    }

    // Review Focus 8: a call made before the route is decided waits and goes to the store the
    // route names.
    func testReadsWaitForTheRoute() async throws {
        let gate = Gate()
        let r = RecordRoute(file: file, decided: { false }, account: {
            await gate.wait()
            return .noAccount
        })
        let cloud = InMemoryRecordDatabase()
        _ = try await cloud.save(Record(type: "T", id: RecordID("cloud-only")))
        let db = RoutedRecordDatabase(route: r, cloud: cloud)
        async let early = db.fetch(RecordID("cloud-only"))
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        let found = try await early
        XCTAssertNil(found, "answered from the journal, not CloudKit")
        _ = try await db.save(Record(type: "T", id: RecordID("on-the-phone")))
        let kept = try LocalRecordDatabase(file: file)
        let onDisk = await kept.current(RecordID("on-the-phone"))
        XCTAssertNotNil(onDisk)
        let inCloud = await cloud.current(RecordID("on-the-phone"))
        XCTAssertNil(inCloud)
    }

    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// The role at first launch on the journal: no lease to read, so the phone stakes the first
    /// claim and is primary, and a relaunch finds its own lease.
    @MainActor
    func testANoAccountPhoneIsPrimaryAndStaysSoAcrossARelaunch() async throws {
        let suite = "topo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let me = DeviceID("ios-test")
        let r = RecordRoute(file: file, decided: { RoleSelector.hasDecided(UserDefaults(suiteName: suite)!) },
                            account: { .noAccount })
        let selector = RoleSelector(database: RoutedRecordDatabase(route: r, cloud: InMemoryRecordDatabase()),
                                    device: me, defaults: defaults, isSignedIn: { false }, ensureZone: {})
        await selector.decide()
        XCTAssertEqual(selector.role, .primary)
        XCTAssertNil(selector.trouble)
        XCTAssertTrue(RoleSelector.hasDecided(defaults))
        let relaunched = try LocalRecordDatabase(file: file)
        let record = try await relaunched.fetch(Lease.recordID)
        XCTAssertEqual(Lease(record: try XCTUnwrap(record))?.holder, me)
    }

    /// A journal that fails to open and then opens, with many callers waiting and retrying, is
    /// one journal: every caller that is answered gets the same instance, so no two append to
    /// the one file.
    func testAJournalThatFailsThenOpensIsOneJournalForEveryCaller() async throws {
        for _ in 0..<20 {
            try? FileManager.default.removeItem(at: folder)
            // The journal's folder is a file, so the first opens fail.
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: folder)
            let r = RecordRoute(file: file, decided: { false }, account: { .noAccount }, pause: { _ in })
            let blocker = Blocker(folder)
            let opened = try await withThrowingTaskGroup(of: ObjectIdentifier?.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        while true {
                            do {
                                guard case .local(let db) = try await r.route() else { return nil }
                                return ObjectIdentifier(db)
                            } catch {
                                // The first failure clears the way, so the callers that waited
                                // on the failed open and the ones that come after all retry.
                                await blocker.clear()
                                await Task.yield()
                            }
                        }
                    }
                }
                var all: Set<ObjectIdentifier?> = []
                for try await id in group { all.insert(id) }
                return all
            }
            XCTAssertEqual(opened.count, 1, "one journal for every caller")
        }
    }

    actor Blocker {
        let url: URL
        var cleared = false
        init(_ url: URL) { self.url = url }
        func clear() {
            guard !cleared else { return }
            cleared = true
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A journal that would not open is not the login's evidence: the role stays undecided with
    /// the journal's words, and nothing sends the phone to CloudKit.
    @MainActor
    func testAJournalThatWillNotOpenDecidesNoRoleEvenSignedIn() async throws {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: folder)
        let suite = "topo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let r = RecordRoute(file: file, decided: { RoleSelector.hasDecided(UserDefaults(suiteName: suite)!) },
                            account: { .noAccount })
        let selector = RoleSelector(database: RoutedRecordDatabase(route: r, cloud: InMemoryRecordDatabase()),
                                    device: DeviceID("ios-test"), defaults: defaults, isSignedIn: { true }, ensureZone: {})
        await selector.decide()
        XCTAssertNil(selector.role)
        XCTAssertFalse(RoleSelector.hasDecided(defaults))
        XCTAssertEqual(selector.trouble?.hasPrefix("Topo couldn't read or write the conversation"), true, selector.trouble ?? "nil")
    }

    /// On the journal a phone that is signed in is primary by its first claim, as on CloudKit.
    @MainActor
    func testASignedInNoAccountPhoneIsPrimary() async throws {
        let suite = "topo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let r = RecordRoute(file: file, decided: { RoleSelector.hasDecided(UserDefaults(suiteName: suite)!) },
                            account: { .noAccount })
        let selector = RoleSelector(database: RoutedRecordDatabase(route: r, cloud: InMemoryRecordDatabase()),
                                    device: DeviceID("ios-test"), defaults: defaults, isSignedIn: { true }, ensureZone: {})
        await selector.decide()
        XCTAssertEqual(selector.role, .primary)
        let store = try await r.store()
        XCTAssertEqual(store, .local)
    }

    /// A refusal for want of an account is said as that, not as a refusal.
    @MainActor
    func testNoAccountIsSaidAsNoAccount() {
        let error = RecordDatabaseError.rejected(underlying: CKError(.notAuthenticated))
        XCTAssertEqual(TranscriptStore.message(for: error), "No iCloud account on this phone. Sign in to iCloud in Settings.")
        XCTAssertEqual(TranscriptStore.message(for: RecordDatabaseError.rejected(underlying: CKError(.permissionFailure))),
                       "iCloud refused the read. Check you're signed in on this device.")
    }
}
