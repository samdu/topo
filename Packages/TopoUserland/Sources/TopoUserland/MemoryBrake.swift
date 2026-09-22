import Dispatch
import TopoIsh

/// The guest's memory brake, seen from the app. The kernel refuses a guest's new anonymous memory
/// (`mmap`, `brk`) when the app's footprint is within a tenth of its jetsam line, and fails closed
/// when its last sample of that line is more than two seconds old; the app is what feeds it the
/// samples. On a stale sample the kernel first asks the app for a fresh one through the refresh
/// hook — Topo's patch to the fork's kernel/mmap.c, `patches/ish/0001-memory-brake-refresh.patch`
/// — because a suspended app's timer stops, and on resume the guest runs before the timer does.
public enum MemoryBrake {
    /// What the kernel calls on a stale sample. A C function, since the kernel calls it.
    public typealias Refresh = @convention(c) () -> Void

    /// The production hook: reads this process's footprint and what it may still allocate and
    /// feeds them, as `sample()` does.
    public static let sampleNow: Refresh = topo_ish_memory_refresh

    /// Feeds a sample: `limit` is the jetsam line (footprint plus what is still available),
    /// `available` what is still available. The first feed puts the kernel in footprint mode for
    /// the life of the process.
    public static func feed(limit: UInt64, available: UInt64, critical: Bool = false) {
        topo_ish_memory_feed(limit, available, critical)
    }

    /// Reads this process's footprint and available memory and feeds them. False, and nothing
    /// fed, when either reads as zero: a simulator has no jetsam line to read.
    @discardableResult
    public static func sample(critical: Bool = false) -> Bool {
        topo_ish_memory_sample(critical)
    }

    /// Sets the hook the kernel calls on a stale sample; nil fails closed at once.
    public static func setRefresh(_ hook: Refresh?) {
        topo_ish_set_memory_refresh(hook)
    }

    /// Whether the kernel would admit `bytes` of new anonymous memory now: the one decision every
    /// guest allocation passes through (`ish_mem_commit_ok`).
    public static func admits(_ bytes: UInt64) -> Bool {
        topo_ish_memory_admits(bytes)
    }
}

/// The app's side of the brake while the guest runs: a sample every 250 ms and on every memory
/// pressure event, as the fork's own app feeds it, with `MemoryBrake.sampleNow` as the refresh
/// hook so a sample gone stale behind the app's back is renewed before anything fails closed.
public final class MemorySampler: @unchecked Sendable {
    public static let shared = MemorySampler()

    private let queue = DispatchQueue(label: "zone.hexagon.topo.userland.memory", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?

    /// Whether the timer is running. Read and written on `queue`.
    public var running: Bool { queue.sync { timer != nil } }

    /// Installs the refresh hook, feeds one sample now so the first guest process meets a fresh
    /// one, and starts the timer and the pressure source. Idempotent.
    public func start() {
        queue.sync {
            MemoryBrake.setRefresh(MemoryBrake.sampleNow)
            MemoryBrake.sample()
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
            timer.setEventHandler { MemoryBrake.sample() }
            timer.resume()
            self.timer = timer
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            pressure.setEventHandler { [weak pressure] in
                MemoryBrake.sample(critical: pressure?.data.contains(.critical) ?? false)
            }
            pressure.resume()
            self.pressure = pressure
        }
    }

    /// Stops the timer and the pressure source; the refresh hook stays as it is. Once this
    /// returns no sample from them is being fed, since both run on `queue`.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pressure?.cancel()
            pressure = nil
        }
    }
}
