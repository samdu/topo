import Foundation
import MetricKit
import TopoCore
import UIKit
import os

/// The phone's own account of what this process costs: a line a minute while the process runs,
/// and MetricKit's daily payloads as they land. Nothing leaves the phone.
///
/// The pulse is the kernel's counters for this task (`TASK_POWER_INFO`): CPU time and idle
/// wakeups since the last pulse, against the battery, the charger, the thermal state and Low Power
/// Mode, with what the app was doing (`state`), and the threads the minute went to by name. It is
/// what Instruments would read, without the cable. Each line is a `Perf` mark (`energy …`), so it
/// is in the unified log under `perf` and in a timed run's file; and it is appended to
/// `tmp/topo-energy.log` in the container, which `devicectl device copy from` reads off a phone
/// nobody is at. Only this process: the audio server's and the emulator's host-side share are
/// Instruments' alone.
///
/// MetricKit adds the system's view, once a day: per-process CPU, display and network energy, time
/// in the foreground and the background. Each payload is kept in Application Support/metrickit, the
/// newest fourteen, for the diagnostics screen and a person asked to send one.
///
/// Phone target only. Main actor, except where said.
@MainActor
final class EnergyPulse: NSObject, MXMetricManagerSubscriber {
    static let shared = EnergyPulse()

    static let every: TimeInterval = 60
    /// The container file is started afresh past this size: a log, not an archive.
    private static let fileCap = 512 * 1024

    /// What the app says about itself on each pulse. Set by `TopoApp`.
    var state: @MainActor () async -> String = { "" }
    /// The last pulse's line, for the diagnostics screen.
    private(set) var last: String?
    /// How many MetricKit payloads are kept, and when the newest arrived.
    private(set) var payloads: (count: Int, newest: Date?) = (0, nil)

    private var timer: DispatchSourceTimer?
    private var counters: (cpu: Double, idle: UInt64, interrupts: UInt64, at: Date)?
    private var started = false
    private var file: FileHandle?

    private override init() {}

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        // A profiling run from a Mac (`--stay-awake`) holds auto-lock off, since a locked phone
        // takes no launch and no copy; nothing else here touches the idle timer.
        if ProcessInfo.processInfo.arguments.contains("--stay-awake") {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        mainThread = pthread_self()
        MXMetricManager.shared.add(self)
        counters = Self.read().map { ($0.cpu, $0.idle, $0.interrupts, Date()) }
        openFile()
        payloads = Self.kept()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.every, repeating: Self.every, leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.pulse() }
        }
        t.resume()
        timer = t
    }

    // MARK: Pulse

    private func pulse() async {
        guard let now = Self.read(), let last = counters else { return }
        let dt = Date().timeIntervalSince(last.at)
        guard dt > 0 else { return }
        counters = (now.cpu, now.idle, now.interrupts, Date())
        let cpu = now.cpu - last.cpu
        let idle = now.idle &- last.idle
        let ints = now.interrupts &- last.interrupts
        let dev = UIDevice.current
        let charging: String
        switch dev.batteryState {
        case .charging: charging = "charging"
        case .full: charging = "full"
        case .unplugged: charging = "unplugged"
        default: charging = "battery unknown"
        }
        let p = ProcessInfo.processInfo
        let thermal: String
        switch p.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "thermal ?"
        }
        let app = UIApplication.shared.applicationState
        let line = String(
            format: "energy cpu %.1f%% of a core (%.2fs in %.0fs), wakeups %.0f/s idle %.0f/s interrupt, "
                + "battery %.0f%% %@, thermal %@, lpm %@, %@, %@",
            cpu / dt * 100, cpu, dt, Double(idle) / dt, Double(ints) / dt,
            dev.batteryLevel * 100, charging, thermal,
            p.isLowPowerModeEnabled ? "on" : "off",
            app == .active ? "fg" : app == .background ? "bg" : "inactive",
            await state())
        self.last = line
        write(line)
        let threads = topThreads()
        if !threads.isEmpty { write("energy threads " + threads) }
    }

    private func write(_ line: String) {
        Perf.mark(line)
        let stamped = "\(Int64(Date().timeIntervalSince1970)) \(line)\n"
        file?.write(Data(stamped.utf8))
    }

    /// `tmp/topo-energy.log`, appended to; started afresh when it has grown past the cap.
    private func openFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topo-energy.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > Self.fileCap || size == 0 {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        file = handle
    }

    // MARK: Threads

    private var threadLast: [UInt64: Double] = [:]
    private var mainThread: pthread_t?

    /// The threads that spent the most CPU since the last pulse, by name: what a Time Profiler
    /// would say about a minute, from inside. Unnamed threads are summed as one.
    private func topThreads() -> String {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list
        else { return "" }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list),
                          vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var seen: [UInt64: Double] = [:]
        var merged: [String: Double] = [:]
        for i in 0..<Int(count) {
            let t = list[i]
            var basic = thread_basic_info_data_t()
            var n = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(t, thread_flavor_t(THREAD_BASIC_INFO), $0, &n)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            var ident = thread_identifier_info_data_t()
            var m = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr2 = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(m)) {
                    thread_info(t, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &m)
                }
            }
            guard kr2 == KERN_SUCCESS else { continue }
            let cpu = Double(basic.user_time.seconds + basic.system_time.seconds)
                + Double(basic.user_time.microseconds + basic.system_time.microseconds) / 1e6
            seen[ident.thread_id] = cpu
            let delta = cpu - (threadLast[ident.thread_id] ?? 0)
            guard delta >= 0.05 else { continue }
            var name = ""
            if let p = pthread_from_mach_thread_np(t) {
                if let main = mainThread, pthread_equal(p, main) != 0 {
                    name = "main"
                } else {
                    var buf = [CChar](repeating: 0, count: 64)
                    pthread_getname_np(p, &buf, 64)
                    name = String(cString: buf)
                }
            }
            if name.isEmpty { name = "unnamed" }
            merged[name, default: 0] += delta
        }
        threadLast = seen
        return merged.sorted { $0.value > $1.value }.prefix(8)
            .map { String(format: "%@ %.2fs", $0.key, $0.value) }.joined(separator: ", ")
    }

    // MARK: Counters

    /// This task's CPU seconds and wakeups since it started.
    private static func read() -> (cpu: Double, idle: UInt64, interrupts: UInt64)? {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Double(info.total_user + info.total_system) * tick,
                info.task_platform_idle_wakeups, info.task_interrupt_wakeups)
    }

    /// `TASK_POWER_INFO` times are Mach absolute-time ticks: ~41.7 ns on Apple silicon.
    private static let tick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    // MARK: MetricKit

    private static let keep = 14

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let kept = payloads.map { ($0.jsonRepresentation(), $0.timeStampEnd, Self.headline($0)) }
        Task { @MainActor in
            for (json, at, headline) in kept {
                Self.save(json, at: at, prefix: "metrics")
                self.write("energy metrickit \(headline)")
            }
            self.payloads = Self.kept()
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let kept = payloads.map { ($0.jsonRepresentation(), $0.timeStampEnd) }
        Task { @MainActor in
            for (json, at) in kept { Self.save(json, at: at, prefix: "diagnostics") }
            self.payloads = Self.kept()
        }
    }

    /// The payload's day in one line: the CPU it charged this process, the time in front and
    /// behind, and the cellular share of its network.
    private nonisolated static func headline(_ p: MXMetricPayload) -> String {
        var parts: [String] = []
        let f = ISO8601DateFormatter()
        parts.append("\(f.string(from: p.timeStampBegin))..\(f.string(from: p.timeStampEnd))")
        if let cpu = p.cpuMetrics {
            parts.append("cpu \(Int(cpu.cumulativeCPUTime.converted(to: .seconds).value))s")
        }
        if let time = p.applicationTimeMetrics {
            parts.append("fg \(Int(time.cumulativeForegroundTime.converted(to: .minutes).value))m")
            parts.append("bg \(Int(time.cumulativeBackgroundTime.converted(to: .minutes).value))m")
            parts.append("audio \(Int(time.cumulativeBackgroundAudioTime.converted(to: .minutes).value))m")
        }
        if let net = p.networkTransferMetrics {
            let cell = net.cumulativeCellularDownload.converted(to: .megabytes).value
                + net.cumulativeCellularUpload.converted(to: .megabytes).value
            let wifi = net.cumulativeWifiDownload.converted(to: .megabytes).value
                + net.cumulativeWifiUpload.converted(to: .megabytes).value
            parts.append(String(format: "net cell %.1fMB wifi %.1fMB", cell, wifi))
        }
        return parts.joined(separator: " ")
    }

    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let d = base.appendingPathComponent("metrickit", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func save(_ json: Data, at: Date, prefix: String) {
        guard let dir else { return }
        let name = "\(prefix)-\(Int64(at.timeIntervalSince1970)).json"
        try? json.write(to: dir.appendingPathComponent(name), options: .atomic)
        // The newest `keep` stay; a name sorts by its time stamp.
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for old in files.dropLast(keep) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }

    private static func kept() -> (count: Int, newest: Date?) {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return (0, nil) }
        let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        return (files.count, newest)
    }
}
