import Foundation
import OSLog

/// Where the time goes, in the unified log: one `notice` line per named moment, under the `perf`
/// category, so a launch's or a turn's timeline is read off a device with `log collect` and the
/// log's own clock. A mark carries a name and nothing of the person's.
public enum Perf {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "perf")

    public static func mark(_ name: String) {
        log.notice("mark \(name, privacy: .public)")
    }

    /// Milliseconds since the process was started, from the kernel's own record of it: what a
    /// launch spent before any of the app's code ran.
    public static func sinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return (now.tv_sec - started.tv_sec) * 1000 + Int(now.tv_usec - started.tv_usec) / 1000
    }
}
