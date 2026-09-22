import Dispatch
import Foundation
import TopoIsh

/// The guest: one iSH kernel per process, booted on a fakefs, running programs as children of an
/// init that never runs one of its own. The kernel is process-global state, so there is one
/// `Guest` and it boots at most once; every boot after the first is refused, whatever the first
/// answered.
public final class Guest: Sendable {
    public static let shared = Guest()

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// This process has already booted a kernel, or tried to.
        case alreadyBooted
        /// The kernel refused the boot, with its (negative, guest) errno.
        case boot(Int32)
        /// The program could not be started, with the guest errno.
        case spawn(Int32)
        /// The program could not be waited for, with the guest errno.
        case wait(Int32)

        public var description: String {
            switch self {
            case .alreadyBooted: "the guest is already booted in this process"
            case .boot(let errno): "the kernel refused to boot (\(errno))"
            case .spawn(let errno): "the program could not be started (\(errno))"
            case .wait(let errno): "the program could not be waited for (\(errno))"
            }
        }
    }

    /// What a program left behind: its status (the exit code, or 128 plus the signal that ended
    /// it) and everything it wrote to stdout and stderr.
    public struct Exit: Sendable, Equatable {
        public let status: Int32
        public let output: String
        public let errors: String
    }

    /// The environment a program gets when it is given none: root's home and the usual path.
    public static let environment = [
        "HOME": "/root",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]

    private init() {}

    /// How many kernels this process has made: 0 before a boot, 1 after, never more.
    public var kernels: Int { Int(topo_ish_kernels()) }

    /// Boots the kernel on the fakefs at `fakefs` (a directory holding `meta.db` and `data/`, as
    /// `RootfsInstaller` makes it), and starts the app's side of the memory brake.
    public func boot(fakefs: URL) throws {
        let result = fakefs.withUnsafeFileSystemRepresentation { topo_ish_boot($0) }
        if result == TOPO_ISH_ALREADY_BOOTED { throw Failure.alreadyBooted }
        if result != 0 { throw Failure.boot(result) }
        MemorySampler.shared.start()
    }

    /// Runs `path` with `arguments` to its end and returns what it left. The work is blocking —
    /// two pipe reads and a wait on the kernel — so it runs on a queue of its own, never on the
    /// cooperative pool. The reads end when every guest descriptor on the pipes closes, so a
    /// program that leaves a child holding them keeps this waiting for that child too.
    public func run(_ path: String, _ arguments: [String] = [],
                    environment: [String: String] = Guest.environment) async throws -> Exit {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runToEnd(path, arguments, environment) })
            }
        }
    }

    private static func runToEnd(_ path: String, _ arguments: [String], _ environment: [String: String]) throws -> Exit {
        let argv = [path] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var out: Int32 = -1, err: Int32 = -1
        let pid = withCStrings(argv) { argv in
            withCStrings(envp) { envp in topo_ish_spawn(path, argv, envp, &out, &err) }
        }
        guard pid > 0 else { throw Failure.spawn(pid) }

        let output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        let errors = FileHandle(fileDescriptor: err, closeOnDealloc: true)
        let reads = DispatchGroup()
        let collected = Collected()
        DispatchQueue.global(qos: .userInitiated).async(group: reads) {
            collected.set(output: output.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .userInitiated).async(group: reads) {
            collected.set(errors: errors.readDataToEndOfFile())
        }
        var status: Int32 = 0
        let waited = topo_ish_wait(pid, &status)
        reads.wait()
        guard waited == 0 else { throw Failure.wait(waited) }
        return Exit(status: status,
                    output: String(decoding: collected.output, as: UTF8.self),
                    errors: String(decoding: collected.errors, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(output: Data) { lock.withLock { out = output } }
        func set(errors: Data) { lock.withLock { err = errors } }
        var output: Data { lock.withLock { out } }
        var errors: Data { lock.withLock { err } }
    }
}

/// `strings` as a NULL-terminated array of C strings for the length of `body`.
private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } } + [nil]
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
