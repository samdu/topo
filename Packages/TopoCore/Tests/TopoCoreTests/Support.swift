import Foundation
import TopoCore
import TopoCoreTesting

/// A clock tests move by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

    var read: @Sendable () -> Date { { [self] in self.now } }
}

/// A probe with a scripted answer, counting who it was asked about.
actor StubProbe: LeaseProbe {
    private let alive: @Sendable (Lease) -> Bool
    private(set) var asked: [DeviceID] = []

    init(alive: @escaping @Sendable (Lease) -> Bool) { self.alive = alive }

    static var allAlive: StubProbe { StubProbe { _ in true } }
    static var allDead: StubProbe { StubProbe { _ in false } }

    func answers(_ lease: Lease) async -> Bool {
        asked.append(lease.holder)
        return alive(lease)
    }
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

extension TurnRef {
    static func ref(_ device: String, _ seq: Int64) -> TurnRef {
        TurnRef(device: DeviceID(device), sequence: seq)
    }
}

let phone = DeviceID("phone")
let hub = DeviceID("hub")
let watch = DeviceID("watch")
