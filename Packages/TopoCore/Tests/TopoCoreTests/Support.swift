import Foundation
import TopoCore
import TopoCoreTesting

/// A clock tests move by hand: a wall clock and a monotonic clock that
/// advance together, except that `wallStep` moves the wall clock alone.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var elapsed: TimeInterval = 0

    init(_ start: Date = tA) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds; elapsed += seconds } }

    /// A clock correction: the wall clock jumps, the monotonic clock does not.
    func wallStep(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

    var read: @Sendable () -> Date { { [self] in self.now } }

    var uptime: @Sendable () -> TimeInterval { { [self] in self.lock.withLock { self.elapsed } } }
}

/// Stands in for the heartbeat loop's sleep: the loop parks here and each
/// `tick()` lets one parked heartbeat through.
actor Ticker {
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    nonisolated var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] _ in await self.park() }
    }

    private func park() async {
        await withCheckedContinuation { sleepers.append($0) }
    }

    func tick() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }

    var sleeping: Int { sleepers.count }
}

/// Yields until `condition` holds. Bounded, so a wrong expectation fails
/// instead of hanging; everything under test completes in a handful of
/// actor hops with no real waiting, so the bound is never reached in a
/// passing test.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// A probe with a scripted answer, counting who it was asked about.
actor StubProbe: LeaseProbe {
    private let alive: @Sendable (Lease) -> Bool
    private(set) var asked: [DeviceID] = []

    init(alive: @escaping @Sendable (Lease) -> Bool) { self.alive = alive }

    static var allAlive: StubProbe { StubProbe { _ in true } }
    static var allDead: StubProbe { StubProbe { _ in false } }

    func confirms(_ lease: Lease) async -> Bool {
        asked.append(lease.holder)
        return alive(lease)
    }
}

/// A probe answering from a mutable set of reachable devices.
actor SetProbe: LeaseProbe {
    private var reachable: Set<String>
    init(_ reachable: Set<String> = []) { self.reachable = reachable }
    func set(_ r: Set<String>) { reachable = r }
    func confirms(_ lease: Lease) async -> Bool { reachable.contains(lease.holder.rawValue) }
}

/// A probe that burns clock time before answering.
actor SlowProbe: LeaseProbe {
    let clock: ManualClock
    let cost: TimeInterval
    let answer: Bool
    init(clock: ManualClock, cost: TimeInterval, answer: Bool) {
        self.clock = clock; self.cost = cost; self.answer = answer
    }
    func confirms(_ lease: Lease) async -> Bool { clock.advance(cost); return answer }
}

/// Releases every waiter once `parties` have arrived, then stays open.
actor Barrier {
    private let parties: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false

    init(parties: Int) { self.parties = parties }

    func arrive() async {
        if open { return }
        if waiting.count + 1 == parties {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// A database whose query index has not caught up with the newest turn of
/// each device: every query drops the highest sequence it would return.
struct StaleTailDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] {
        let all = try await inner.query(query)
        var newest: [String: Int64] = [:]
        for r in all {
            if let d = r.string("device"), let s = r.int("sequence") { newest[d] = max(newest[d] ?? 0, s) }
        }
        return all.filter { r in
            guard let d = r.string("device"), let s = r.int("sequence") else { return true }
            return s != newest[d]
        }
    }
}

/// A database whose query index is permanently cold.
struct BlindQueryDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    func save(_ records: [Record]) async throws -> [Record] { try await inner.save(records) }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { [] }
}

/// A conforming adapter whose `save` echoes a record `Lease` cannot parse.
struct LossySaveDatabase: RecordDatabase {
    let inner: InMemoryRecordDatabase
    func save(_ records: [Record]) async throws -> [Record] {
        var out = try await inner.save(records)
        for i in out.indices { out[i].fields.removeValue(forKey: "expiresAt") }
        return out
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
}

/// Commits the first save, then reports it as a transport failure.
final class FlakyOnceDatabase: RecordDatabase, @unchecked Sendable {
    let inner: InMemoryRecordDatabase
    private let lock = NSLock()
    private var fired = false
    init(inner: InMemoryRecordDatabase) { self.inner = inner }
    func save(_ records: [Record]) async throws -> [Record] {
        let out = try await inner.save(records)
        let first = lock.withLock { () -> Bool in
            if fired { return false }
            fired = true
            return true
        }
        if first {
            struct Dropped: Error {}
            throw RecordDatabaseError.unavailable(underlying: Dropped())
        }
        return out
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await inner.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await inner.query(query) }
}

/// Deterministic pseudo-random numbers for model checks.
struct LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    mutating func int(_ n: Int) -> Int { Int(next() >> 33) % max(n, 1) }
}

func turnRecord(device: String, seq: Int64, parents: [String], role: String = "person",
                text: String = "t", at: Date = tA) -> Record {
    Record(type: Turn.recordType, id: RecordID("turn/\(device)/\(seq)"), fields: [
        "device": .string(device),
        "sequence": .int(seq),
        "parents": .strings(parents),
        "role": .string(role),
        "text": .string(text),
        "at": .date(at),
        "nonce": .string("n-\(device)-\(seq)"),
    ])
}

extension TurnRef {
    static func ref(_ device: String, _ seq: Int64) -> TurnRef {
        TurnRef(device: DeviceID(device), sequence: seq)
    }
}

let tA = Date(timeIntervalSince1970: 1_000_000)
let phone = DeviceID("phone")
let hub = DeviceID("hub")
let watch = DeviceID("watch")
