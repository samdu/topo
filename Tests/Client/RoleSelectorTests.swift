import CloudKit
import TopoCore
import TopoCoreTesting
import XCTest

@testable import Topo

@MainActor
final class RoleSelectorTests: XCTestCase {
    private let me = DeviceID("ios-test")

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")! }

    private func selector(_ database: any RecordDatabase, defaults: UserDefaults? = nil,
                          signedIn: Bool = false) -> RoleSelector {
        RoleSelector(database: database, device: me, defaults: defaults ?? self.defaults(), isSignedIn: { signedIn },
                     ensureZone: {})
    }

    private func lease(_ database: InMemoryRecordDatabase, holder: DeviceID) async throws {
        let lease = PrimaryLease(database: database, device: holder, endpoint: nil, probe: NoProbe(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await lease.acquire() else { return XCTFail("claim") }
    }

    func testNoLeaseRecordMeansPrimaryAndStakesTheLease() async throws {
        let db = InMemoryRecordDatabase()
        let s = selector(db)
        await s.decide()
        XCTAssertEqual(s.role, .primary)
        let record = await db.current(Lease.recordID)
        XCTAssertEqual(Lease(record: try XCTUnwrap(record))?.holder, me)
    }

    func testTwoFreshDevicesLaunchingTogetherGetOnePrimary() async {
        let db = InMemoryRecordDatabase()
        let a = RoleSelector(database: db, device: DeviceID("ios-a"), defaults: defaults(), isSignedIn: { false }, ensureZone: {})
        let b = RoleSelector(database: db, device: DeviceID("ios-b"), defaults: defaults(), isSignedIn: { false }, ensureZone: {})
        async let da: Void = a.decide()
        async let db2: Void = b.decide()
        _ = await (da, db2)
        XCTAssertEqual([a.role, b.role].filter { $0 == .primary }.count, 1)
        XCTAssertEqual([a.role, b.role].filter { $0 == .viewer }.count, 1)
    }

    func testAnotherDevicesLeaseMeansViewerEvenWhenExpired() async throws {
        let db = InMemoryRecordDatabase()
        try await lease(db, holder: DeviceID("ipad"))
        let current = await db.current(Lease.recordID)
        var record = try XCTUnwrap(current)
        record.fields["expiresAt"] = .date(Date(timeIntervalSinceNow: -3600))
        _ = try await db.save(record)
        let s = selector(db)
        await s.decide()
        XCTAssertEqual(s.role, .viewer)
    }

    func testOwnLeaseOrOwnLoginMeansPrimary() async throws {
        let db = InMemoryRecordDatabase()
        try await lease(db, holder: me)
        let own = selector(db)
        await own.decide()
        XCTAssertEqual(own.role, .primary)

        let other = InMemoryRecordDatabase()
        try await lease(other, holder: DeviceID("ipad"))
        let signedIn = selector(other, signedIn: true)
        await signedIn.decide()
        XCTAssertEqual(signedIn.role, .primary)
    }

    func testADecisionIsKeptAcrossLaunches() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = defaults()
        let first = selector(db, defaults: defaults)
        await first.decide()
        XCTAssertEqual(first.role, .primary)
        try await lease(db, holder: DeviceID("ipad"))
        let second = selector(db, defaults: defaults)
        XCTAssertEqual(second.role, .primary)
        await second.decide()
        XCTAssertEqual(second.role, .primary)
    }

    func testNoZoneYetMeansTheZoneIsMadeAndThisDeviceIsPrimary() async throws {
        let db = InMemoryRecordDatabase()
        let gate = ZoneGate(db)
        let s = RoleSelector(database: gate, device: me, defaults: defaults(), isSignedIn: { false },
                             ensureZone: { await gate.open() })
        await s.decide()
        XCTAssertEqual(s.role, .primary)
        let record = await db.current(Lease.recordID)
        XCTAssertNotNil(record)
    }

    func testTakingPrimaryFromALapsedLeaseClaimsAtOnce() async throws {
        let db = InMemoryRecordDatabase()
        try await lease(db, holder: DeviceID("lost-phone"))
        let current = await db.current(Lease.recordID)
        var record = try XCTUnwrap(current)
        record.fields["expiresAt"] = .date(Date(timeIntervalSinceNow: -3600))
        _ = try await db.save(record)
        let slept = Slept()
        let s = RoleSelector(database: db, device: me, defaults: defaults(), isSignedIn: { false }, ensureZone: {},
                             sleep: { await slept.add($0) })
        await s.decide()
        XCTAssertEqual(s.role, .viewer)
        await s.takePrimary()
        XCTAssertEqual(s.role, .primary)
        XCTAssertNil(s.trouble)
        let after = await db.current(Lease.recordID)
        let taken = try XCTUnwrap(Lease(record: try XCTUnwrap(after)))
        XCTAssertEqual(taken.holder, me)
        XCTAssertEqual(taken.epoch, 2)
        let waits = await slept.all
        XCTAssertTrue(waits.isEmpty)
    }

    func testTakingPrimaryFromAFreshLeaseWaitsOneDurationThenClaimsAndTheHolderYields() async throws {
        let db = InMemoryRecordDatabase()
        let holder = PrimaryLease(database: db, device: DeviceID("phone"), endpoint: nil, probe: NoProbe(),
                                  sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        guard case .primary = try await holder.acquire() else { return XCTFail("claim") }
        let slept = Slept()
        let s = RoleSelector(database: db, device: me, defaults: defaults(), isSignedIn: { false }, ensureZone: {},
                             sleep: { await slept.add($0) })
        await s.decide()
        XCTAssertEqual(s.role, .viewer)
        let taken = await s.takePrimary()
        XCTAssertEqual(s.role, .primary)
        // The instance that claimed is handed on, and it holds the lease.
        let holds = await taken?.isPrimary()
        XCTAssertEqual(holds, true)
        let waits = await slept.all
        XCTAssertEqual(waits.count, 1)
        XCTAssertGreaterThan(waits[0], 9)
        XCTAssertLessThanOrEqual(waits[0], 10)
        // The displaced phone learns on its next heartbeat and stops counting itself primary.
        let beat = try await holder.heartbeat()
        XCTAssertFalse(beat)
        let primary = await holder.isPrimary()
        XCTAssertFalse(primary)
    }

    func testAnUnreadableRecordLeavesTheRoleUndecided() async {
        let s = selector(Failing())
        await s.decide()
        XCTAssertNil(s.role)
        XCTAssertNotNil(s.trouble)
    }
}

private struct NoProbe: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { false }
}

private struct Failing: RecordDatabase {
    struct Down: Error {}
    func save(_ records: [Record]) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Down()) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { throw RecordDatabaseError.unavailable(underlying: Down()) }
    func query(_ query: RecordQuery) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Down()) }
    func records(ofType type: String) async throws -> [Record] { throw RecordDatabaseError.unavailable(underlying: Down()) }
}

/// A database whose zone does not exist until `open()`: every call before that is CloudKit's
/// `zoneNotFound`, which is what a fresh Apple ID answers.
private actor ZoneGate: RecordDatabase {
    let wrapped: InMemoryRecordDatabase
    private var isOpen = false
    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }
    func open() { isOpen = true }
    private func check() throws {
        if !isOpen { throw RecordDatabaseError.rejected(underlying: CKError(.zoneNotFound)) }
    }
    func save(_ records: [Record]) async throws -> [Record] { try check(); return try await wrapped.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try check(); return try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try check(); return try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try check(); return try await wrapped.records(ofType: type) }
}

private actor Slept {
    private(set) var all: [TimeInterval] = []
    func add(_ seconds: TimeInterval) { all.append(seconds) }
}
