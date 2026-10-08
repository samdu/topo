import Foundation
import OSLog
import os

/// Where the time goes, in the unified log: one `notice` line per named moment, under the `perf`
/// category, so a launch's or a turn's timeline is read off a device's log; each line carries
/// the wall clock in milliseconds, since a syslog relay keeps whole seconds. A mark carries a name and nothing of the person's.
public enum Perf {
    private static let log = Logger(subsystem: "zone.hexagon.topo", category: "perf")

    /// Where the marks are also written, a line each, when a run is being timed from a Mac
    /// (`PerfRun`): a file `devicectl` can copy off the phone, which the unified log is not
    /// while the phone sleeps.
    private static let file = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    /// Who else is given the name of every mark made in a task and the tasks it starts: a suite
    /// reading the marks of the one turn it runs, which the file, the process's, cannot tell
    /// from another test's.
    @TaskLocal public static var observer: (@Sendable (String) -> Void)?

    public static func mark(_ name: String) {
        observer?(name)
        let line = "mark t=\(Int64(Date().timeIntervalSince1970 * 1000)) \(name)"
        log.notice("\(line, privacy: .public)")
        file.withLock { $0?.write(Data((line + "\n").utf8)) }
    }

    /// Whether a run is being timed, for a mark that costs something to make.
    public static var recording: Bool { file.withLock { $0 != nil } }

    /// Starts `url` empty and writes every mark from here on to it as well.
    public static func record(to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: url)
        file.withLock { $0 = handle }
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
