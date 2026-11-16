import Darwin
import Foundation

/// Lines read off a pipe, handed to one reader at a time. The pipe is read on a thread of its own,
/// so nothing here blocks Swift's cooperative pool; a reader whose task is cancelled gets
/// `.cancelled`, and one whose bound passes with no line `.timedOut`, and the lines stay for the
/// next reader.
final class LineQueue: @unchecked Sendable {
    enum Next: Sendable, Equatable { case line(String), end, cancelled, timedOut }

    private let lock = NSLock()
    private var lines: [String] = []
    private var head = 0
    private var finished = false
    private var waiter: CheckedContinuation<Next, Never>?
    /// Moves at every wait, so a bound's timer resumes only the wait it was set for.
    private var waits = 0

    func push(_ line: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .line(line))
            return
        }
        lines.append(line)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: .end)
    }

    /// The next line, `.end` once the pipe is closed and every line has been read, `.cancelled`, or
    /// `.timedOut` once `bound` has passed with no line. A line and the bound are settled under
    /// one lock, so a line that arrives as the bound passes is either handed over or kept.
    func next(within bound: Duration? = nil) async -> Next {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Next, Never>) in
                lock.lock()
                if head < lines.count {
                    let line = lines[head]
                    head += 1
                    if head > 256 { lines.removeFirst(head); head = 0 }
                    lock.unlock()
                    continuation.resume(returning: .line(line))
                } else if finished {
                    lock.unlock()
                    continuation.resume(returning: .end)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                } else {
                    precondition(waiter == nil, "one reader at a time")
                    waiter = continuation
                    waits &+= 1
                    let wait = waits
                    lock.unlock()
                    if let bound {
                        DispatchQueue.global().asyncAfter(deadline: .now() + bound.seconds) { [self] in
                            lock.lock()
                            guard waits == wait, let waiter else { return lock.unlock() }
                            self.waiter = nil
                            lock.unlock()
                            waiter.resume(returning: .timedOut)
                        }
                    }
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: .cancelled)
        }
    }
}

extension Duration {
    /// The duration in seconds, for a dispatch deadline.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

enum MindProcessError: Error, CustomStringConvertible {
    case spawn(String, Int32)
    case write(Int32)

    var description: String {
        switch self {
        case .spawn(let path, let code): "could not start \(path): \(String(cString: strerror(code)))"
        case .write(let code): "could not write to Claude Code: \(String(cString: strerror(code)))"
        }
    }
}

/// One `claude` process: spawned in a process group of its own with its three pipes, read and
/// waited on by threads of its own, written to on a queue of its own.
///
/// With a lifeline, a watcher (`/bin/sh`, in a group of its own) is started beside it, reading a
/// pipe whose only write end this process holds. Whatever ends this process, a `kill -9`
/// included, closes that end, and the watcher kills the mind's group and every descendant of it
/// at once: Claude Code reads its stdin's end only between turns, so an orphan would otherwise
/// carry the turn under way, its tools included, to its end. The watcher is stopped once the
/// mind is reaped or torn down, so it never kills a group whose id has been used again.
final class MindProcess: @unchecked Sendable {
    let pid: pid_t
    let stdout = LineQueue()
    private let input: Int32
    private let writes = DispatchQueue(label: "topo.mind.stdin")
    private let lock = NSLock()
    private var status: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var errorTail = Data()
    private var inputClosing = false
    private var inputClosed = false
    /// The watcher's pid and the write end of its lifeline, while it watches.
    private var watcher: (pid: pid_t, lifeline: Int32)?

    /// Spawns `executable` with `arguments` and exactly `environment`, in `directory`, with a
    /// watcher beside it when `lifeline` is set.
    init(executable: String, arguments: [String], environment: [String: String], directory: String,
         lifeline: Bool = false) throws {
        var stdinPipe: [Int32] = [-1, -1], stdoutPipe: [Int32] = [-1, -1], stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw MindProcessError.spawn(executable, errno)
        }
        let ours = [stdinPipe[1], stdoutPipe[0], stderrPipe[0]]
        for fd in ours { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A write to a process that has gone fails with EPIPE rather than killing this one.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so a teardown reaches what it starts; every other descriptor of
        // this process closed in it; signals at their defaults and none blocked.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(stdinPipe[0]); close(stdoutPipe[1]); close(stderrPipe[1])
        guard code == 0 else {
            ours.forEach { close($0) }
            throw MindProcessError.spawn(executable, code)
        }
        self.pid = pid
        input = stdinPipe[1]
        watcher = lifeline ? Self.watch(pid) : nil

        let out = stdout
        Self.reader(stdoutPipe[0], name: "topo.mind.stdout") { out.push($0) } end: { out.finish() }
        Self.reader(stderrPipe[0], name: "topo.mind.stderr") { [weak self] line in
            self?.keepError(line)
        } end: {}
        let child = pid
        let thread = Thread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
            lock.lock()
            status = raw
            let waiters = exitWaiters
            exitWaiters = []
            lock.unlock()
            waiters.forEach { $0.resume(returning: raw) }
            // A reaped mind's group id may be used again; the watcher must not outlive it.
            self.stopWatching()
        }
        thread.name = "topo.mind.wait"
        thread.start()
    }

    deinit {
        if !inputClosed { close(input) }
        stopWatching()
    }

    /// The watcher's script: it waits for its stdin to end, then kills the mind's group (`$1`)
    /// and every descendant of the mind it finds, in its group or not.
    static let watcherScript = """
        read -r _
        all="$1"; frontier="$1"
        while [ -n "$frontier" ]; do
          next=""
          for p in $frontier; do next="$next $(/usr/bin/pgrep -P "$p")"; done
          frontier="$(echo $next)"
          all="$all $frontier"
        done
        /bin/kill -9 -- -"$1" $all 2>/dev/null
        """

    /// Starts the watcher of `mind`: nil when it cannot be started, which leaves the mind without one.
    private static func watch(_ mind: pid_t) -> (pid: pid_t, lifeline: Int32)? {
        var line: [Int32] = [-1, -1]
        guard pipe(&line) == 0 else { return nil }
        _ = fcntl(line[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, line[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        let words: [String] = ["/bin/sh", "-c", watcherScript, "topo-mind-lifeline", "\(mind)"]
        let path: [String] = ["PATH=/usr/bin:/bin"]
        let argv = words.map { strdup($0) } + [nil]
        let envp = path.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        close(line[0])
        guard code == 0 else {
            close(line[1])
            return nil
        }
        let watcher = pid
        let thread = Thread {
            var raw: Int32 = 0
            while waitpid(watcher, &raw, 0) == -1 && errno == EINTR {}
        }
        thread.name = "topo.mind.watcher.wait"
        thread.start()
        return (watcher, line[1])
    }

    /// The watcher's pid while it watches, for the suites.
    var watcherPID: pid_t? { lock.withLock { watcher?.pid } }

    /// Stops the watcher without letting it act: it is killed before its lifeline is closed.
    private func stopWatching() {
        guard let gone = lock.withLock({ () -> (pid: pid_t, lifeline: Int32)? in
            defer { watcher = nil }
            return watcher
        }) else { return }
        kill(gone.pid, SIGKILL)
        close(gone.lifeline)
    }

    /// Closes the lifeline as this process's end would, leaving the watcher to act: for the suites.
    func cutLifeline() {
        guard let cut = lock.withLock({ () -> (pid: pid_t, lifeline: Int32)? in
            defer { watcher = nil }
            return watcher
        }) else { return }
        close(cut.lifeline)
    }

    /// Reads `fd` to its end on a thread of its own, a line at a time, split on newline bytes.
    private static func reader(_ fd: Int32, name: String, line: @escaping @Sendable (String) -> Void,
                               end: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    line(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
            close(fd)
            end()
        }
        thread.name = name
        thread.start()
    }

    private func keepError(_ line: String) {
        lock.lock()
        errorTail.append(contentsOf: Array(line.utf8) + [0x0A])
        if errorTail.count > 2048 { errorTail.removeFirst(errorTail.count - 2048) }
        lock.unlock()
    }

    /// The last of what the process wrote to stderr.
    var stderrTail: String {
        lock.withLock { String(decoding: errorTail, as: UTF8.self) }
    }

    var hasExited: Bool { lock.withLock { status != nil } }

    /// Writes one line to stdin, on the process's own queue.
    func write(_ line: String) async throws {
        let data = Array((line + "\n").utf8)
        let fd = input
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writes.async { [self] in
                if lock.withLock({ inputClosing }) { return continuation.resume(throwing: MindProcessError.write(EPIPE)) }
                var offset = 0
                while offset < data.count {
                    let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if written < 0 {
                        if errno == EINTR { continue }
                        return continuation.resume(throwing: MindProcessError.write(errno))
                    }
                    offset += written
                }
                continuation.resume()
            }
        }
    }

    /// The raw wait status, once the process has been reaped.
    func exited() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Ends the process and everything it started, and returns once the process is reaped:
    /// true when nothing of it is left, false when a descendant outlived the bound (`still`
    /// names it). stdin is closed first, then the group and every descendant found are sent
    /// SIGTERM, and after `grace` SIGKILL.
    func terminate(grace: Duration = .seconds(3)) async -> (confirmed: Bool, still: [pid_t]) {
        let descendants = Self.descendants(of: pid)
        closeInput()
        if !hasExited {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            descendants.forEach { kill($0, SIGTERM) }
            if !(await reaped(within: grace)) {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        _ = await exited()
        // What it started, in its group or not, is killed once it is reaped.
        let all = descendants + Self.descendants(of: pid)
        kill(-pid, SIGKILL)
        all.forEach { kill($0, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let left = all.filter(Self.alive) + (kill(-pid, 0) == 0 ? [-pid] : [])
            if left.isEmpty { return (true, []) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let left = all.filter(Self.alive) + (kill(-pid, 0) == 0 ? [-pid] : [])
        return (left.isEmpty, left)
    }

    /// Refuses every later write at once, and closes stdin behind any write already on the queue,
    /// without waiting for it: a write stuck on a full pipe ends with EPIPE once the process dies,
    /// so a teardown that waited here would never send a signal.
    func closeInput() {
        let already = lock.withLock {
            let already = inputClosing
            inputClosing = true
            return already
        }
        guard !already else { return }
        writes.async { [self] in
            lock.withLock { inputClosed = true }
            close(input)
        }
    }

    private func reaped(within bound: Duration) async -> Bool {
        let deadline = ContinuousClock.now + bound
        while ContinuousClock.now < deadline {
            if hasExited { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return hasExited
    }

    /// When a live process started, as a string to compare: with the pid, what tells a process
    /// from a later one given the same pid. Nil when there is none, or it is a zombie.
    static func startTime(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_status != UInt32(SZOMB) else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    /// Kills a process this one did not start (a resident an earlier hub left), its group and its
    /// descendants, and waits a bounded moment for them to go.
    static func reap(left pid: pid_t) async {
        let all = [pid] + descendants(of: pid)
        kill(-pid, SIGKILL)
        all.forEach { kill($0, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, all.contains(where: alive) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether a process is still there and not a zombie.
    static func alive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return kill(pid, 0) == 0 }
        return info.pbi_status != UInt32(SZOMB)
    }

    /// Every process descended from `pid` now, children first.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let bytes = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            // The buffer was zeroed, so whatever unit the count is in, the pids are its non-zero entries.
            for child in children where child > 0 && child != parent && !found.contains(child) {
                found.append(child)
                frontier.append(child)
            }
        }
        return found
    }
}
