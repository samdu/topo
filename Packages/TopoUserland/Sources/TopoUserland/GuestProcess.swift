import Dispatch
import Foundation
import TopoIsh

/// A guest program the app talks to while it runs: its stdin is a pipe the app writes to, its
/// stdout arrives line by line as it is written, and it is ended on purpose rather than waited
/// out. Every blocking call — the two reads, the writes, the wait, the kernel's pid table — runs
/// on a queue of the process's own, never on the cooperative pool.
public final class GuestProcess: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// stdin was closed, by the app or because nothing in the guest reads it any more.
        case inputClosed
        /// A write to stdin failed with this host errno.
        case write(Int32)

        public var description: String {
            switch self {
            case .inputClosed: "the program's input is closed"
            case .write(let errno): "the write to the program failed (errno \(errno))"
            }
        }
    }

    /// What ending a process came to. It is confirmed only when all three held within the bound:
    /// the process was reaped, nothing of its tree is still running, and both of its pipes closed.
    public struct Termination: Sendable, Equatable, CustomStringConvertible {
        /// The reaped status (the exit code, or 128 plus the signal), nil when it was not reaped.
        public let status: Int32?
        /// How many tasks the kill reached, the process itself included.
        public let signalled: Int
        /// How many of those tasks, and any they started meanwhile, were still running at the end.
        public let running: Int
        /// Whether stdout and stderr both reached their end.
        public let pipesClosed: Bool

        public init(status: Int32?, signalled: Int, running: Int, pipesClosed: Bool) {
            self.status = status
            self.signalled = signalled
            self.running = running
            self.pipesClosed = pipesClosed
        }

        public var confirmed: Bool { status != nil && running == 0 && pipesClosed }

        public var description: String {
            let reaped = status.map { "reaped (status \($0))" } ?? "not reaped"
            return "\(reaped), \(signalled) signalled, \(running) still running, pipes \(pipesClosed ? "closed" : "open")"
        }
    }

    public let pid: Int32
    /// stdout, one line at a time without its newline, finishing when every guest descriptor on
    /// the pipe has closed. A last line with no newline is delivered at the end.
    public let lines: AsyncStream<String>
    private let state: State
    private let input: Int32
    /// Where the kill and its confirmation run.
    private let queue: DispatchQueue
    /// Where every write to stdin, and its close, run in order: a close never lands while a write
    /// is still using the descriptor.
    private let inputQueue: DispatchQueue

    /// How much of stderr is kept: the end of it, which is where a program says why it stopped.
    static let errorTail = 16 * 1024

    init(pid: Int32, input: Int32, output: Int32, errors: Int32) {
        self.pid = pid
        self.input = input
        let state = State()
        self.state = state
        let label = "zone.hexagon.topo.guest.\(pid)"
        queue = DispatchQueue(label: "\(label).control")
        inputQueue = DispatchQueue(label: "\(label).stdin")
        let (lines, continuation) = AsyncStream<String>.makeStream()
        self.lines = lines
        DispatchQueue(label: "\(label).stdout").async {
            Self.read(output) { chunk in state.splitter.feed(chunk).forEach { continuation.yield($0) } }
            if let last = state.splitter.finish() { continuation.yield(last) }
            continuation.finish()
            state.closed(stdout: true)
        }
        DispatchQueue(label: "\(label).stderr").async {
            Self.read(errors) { chunk in state.appendError(chunk) }
            state.closed(stdout: false)
        }
        DispatchQueue(label: "\(label).wait").async {
            var status: Int32 = 0
            let waited = topo_ish_wait(pid, &status)
            state.exited(waited == 0 ? status : nil)
        }
    }

    deinit {
        closeInput()
    }

    /// The end of what the program wrote to stderr, up to `errorTail` bytes.
    public var errors: String { state.errorText }

    /// The status the process was reaped with, once it has been; nil while it runs, and nil for
    /// good when the wait itself failed.
    public var exitStatus: Int32? { state.status ?? nil }

    /// Whether the process has been reaped (or its wait failed).
    public var hasExited: Bool { state.status != nil }

    /// Writes `line` and a newline to stdin, whole, on the process's own queue.
    public func write(_ line: String) async throws {
        let data = Array((line + "\n").utf8)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            inputQueue.async { [state, input] in
                done.resume(with: Result { try state.write(data, to: input) })
            }
        }
    }

    /// Closes stdin: the program reads its end. Idempotent. A write not yet made when this is
    /// called fails with `inputClosed`, and the descriptor is closed only after it has.
    public func closeInput() {
        state.refuseInput()
        inputQueue.async { [state, input] in state.closeInput(input) }
    }

    /// Ends the process and everything under it and confirms it: stdin closed, SIGKILL to the
    /// whole tree as the pid table stands, then, until `bound` runs out, the process reaped, every
    /// task of the tree (and any it started meanwhile, killed as it is found) no longer running and
    /// both pipes at their end. Answers what it came to; a termination that is not `confirmed` is
    /// one the bound ran out on.
    public func terminate(within bound: Duration = .seconds(5)) async -> Termination {
        // Refused first so nothing new is written; closed after the kill, which is what fails a
        // write already blocked on a full pipe and lets the close behind it run.
        state.refuseInput()
        return await withCheckedContinuation { (done: CheckedContinuation<Termination, Never>) in
            queue.async { [self] in
                let termination = self.killAndConfirm(within: bound)
                self.closeInput()
                done.resume(returning: termination)
            }
        }
    }

    private func killAndConfirm(within bound: Duration) -> Termination {
        let deadline = ContinuousClock.now + bound
        var tree = Self.signalTree(pid, TOPO_ISH_SIGKILL)
        let signalled = tree.count
        // The process itself is its waiter's to reap; the rest are this loop's to watch.
        var others = Set(tree.filter { $0 != pid })
        var running = others.count
        while true {
            // Anything of the tree still running is killed again, and whatever it started since
            // the first walk is found and killed with it.
            var alive: [Int32] = hasExited ? [] : Self.signalTree(pid, TOPO_ISH_SIGKILL)
            for task in others where Self.running([task]) > 0 {
                tree = Self.signalTree(task, TOPO_ISH_SIGKILL)
                alive.append(contentsOf: tree)
            }
            others.formUnion(alive.filter { $0 != pid })
            running = Self.running(Array(others))
            if !hasExited { running += 1 }
            if running == 0 && state.pipesClosed { break }
            if ContinuousClock.now >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return Termination(status: exitStatus, signalled: signalled, running: running, pipesClosed: state.pipesClosed)
    }

    /// The pids of the live tree under `pid`, having sent it `signal` (0 sends nothing).
    static func signalTree(_ pid: Int32, _ signal: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 512)
        let live = pids.withUnsafeMutableBufferPointer {
            topo_ish_signal_tree(pid, signal, $0.baseAddress, Int32($0.count))
        }
        return live > 0 ? Array(pids.prefix(Int(min(live, 512)))) : []
    }

    /// How many of `pids` are still running, reaping any that init was left holding.
    static func running(_ pids: [Int32]) -> Int {
        guard !pids.isEmpty else { return 0 }
        return Int(pids.withUnsafeBufferPointer { topo_ish_running($0.baseAddress, Int32($0.count)) })
    }

    /// The live tree under this process, the process first, as the pid table stands now.
    public func tree() async -> [Int32] {
        await withCheckedContinuation { (done: CheckedContinuation<[Int32], Never>) in
            queue.async { [pid] in done.resume(returning: Self.signalTree(pid, 0)) }
        }
    }

    /// How many of `pids` are running now (a task that exists and is not a zombie).
    public static func running(_ pids: [Int32]) async -> Int {
        await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: running(pids)) }
        }
    }

    /// Reads `fd` to its end, handing each chunk over, then closes it.
    private static func read(_ fd: Int32, _ chunk: (ArraySlice<UInt8>) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk(buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(fd)
    }

    /// What the process's queues share, under one lock.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var inputOpen = true
        private var inputClosed = false
        private var stdoutClosed = false, stderrClosed = false
        private var errorBytes: [UInt8] = []
        /// nil while running; `.some(nil)` when the wait failed.
        private var reaped: Int32??
        let splitter = LineSplitter()

        func write(_ bytes: [UInt8], to fd: Int32) throws {
            guard lock.withLock({ inputOpen }) else { throw Failure.inputClosed }
            var at = 0
            while at < bytes.count {
                let written = bytes[at...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    at += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    let code = errno
                    if code == EPIPE || code == EBADF { throw Failure.inputClosed }
                    throw Failure.write(code)
                }
            }
        }

        /// No write asked for from here on is made.
        func refuseInput() { lock.withLock { inputOpen = false } }

        /// Closes the descriptor once; called on the input queue alone.
        func closeInput(_ fd: Int32) {
            let first = lock.withLock { () -> Bool in
                defer { inputClosed = true }
                return !inputClosed
            }
            if first { close(fd) }
        }

        func appendError(_ chunk: ArraySlice<UInt8>) {
            lock.withLock {
                errorBytes.append(contentsOf: chunk)
                if errorBytes.count > GuestProcess.errorTail {
                    errorBytes.removeFirst(errorBytes.count - GuestProcess.errorTail)
                }
            }
        }

        var errorText: String { lock.withLock { String(decoding: errorBytes, as: UTF8.self) } }

        func closed(stdout: Bool) {
            lock.withLock { if stdout { stdoutClosed = true } else { stderrClosed = true } }
        }

        var pipesClosed: Bool { lock.withLock { stdoutClosed && stderrClosed } }

        func exited(_ status: Int32?) { lock.withLock { reaped = .some(status) } }

        var status: Int32?? { lock.withLock { reaped } }
    }
}

/// Bytes into lines: everything up to each newline, the newline dropped (and a carriage return
/// before it), decoded as UTF-8 only once the line is whole, so a character split across two reads
/// is never mangled.
final class LineSplitter: @unchecked Sendable {
    private var pending: [UInt8] = []

    func feed(_ chunk: ArraySlice<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 0x0A {
                if pending.last == 0x0D { pending.removeLast() }
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// What is left with no newline after it, if anything.
    func finish() -> String? {
        defer { pending = [] }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

extension Guest {
    /// Starts `path` with `arguments` as a process the app talks to: stdin a pipe, stdout read line
    /// by line as it arrives, stderr's end kept. `run` is the call for a program that is run to its
    /// end; this one is for a program that stays. The spawn is made on a queue of its own.
    public func spawn(_ path: String, _ arguments: [String] = [],
                      environment: [String: String] = Guest.environment) async throws -> GuestProcess {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.start(path, arguments, environment) })
            }
        }
    }

    private static func start(_ path: String, _ arguments: [String], _ environment: [String: String]) throws -> GuestProcess {
        let argv = [path] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var input: Int32 = -1, out: Int32 = -1, err: Int32 = -1
        let pid = withCStrings(argv) { argv in
            withCStrings(envp) { envp in topo_ish_spawn(path, argv, envp, &input, &out, &err) }
        }
        guard pid > 0 else { throw Failure.spawn(pid) }
        return GuestProcess(pid: pid, input: input, output: out, errors: err)
    }
}
