import Dispatch
import Foundation
import TopoIsh
import TopoResolv

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
        /// A host directory could not be mounted, with the guest errno.
        case mount(Int32)
        /// A link could not be made, with the guest errno.
        case link(Int32, path: String)
        /// A mount could not be taken away, with the guest errno (`-16`, EBUSY, while anything in
        /// the guest holds it).
        case unmount(Int32)
        /// `/etc/resolv.conf` could not be written, with what the guest said.
        case resolver(String)
        /// `/tmp` could not be emptied, with what the guest said.
        case temporary(String)
        /// `/etc/localtime` could not be pointed at the zone: not a zone name, no zoneinfo for it in
        /// the guest, or the write failed, with why.
        case timeZone(String)

        public var description: String {
            switch self {
            case .alreadyBooted: "the guest is already booted in this process"
            case .boot(let errno): "the kernel refused to boot (\(errno))"
            case .spawn(let errno): "the program could not be started (\(errno))"
            case .wait(let errno): "the program could not be waited for (\(errno))"
            case .mount(let errno): "the directory could not be mounted (\(errno))"
            case .link(let errno, let path): "the link at \(path) could not be made (\(errno))"
            case .unmount(let errno): "the directory could not be unmounted (\(errno))"
            case .resolver(let why): "the guest's resolver could not be written: \(why)"
            case .temporary(let said): "/tmp could not be emptied: \(said)"
            case .timeZone(let why): "/etc/localtime could not be written: \(why)"
            }
        }
    }

    /// What a program left behind: its status (the exit code, or 128 plus the signal that ended
    /// it) and everything it wrote to stdout and stderr.
    public struct Exit: Sendable, Equatable {
        public let status: Int32
        public let output: String
        public let errors: String

        public init(status: Int32, output: String, errors: String) {
            self.status = status
            self.output = output
            self.errors = errors
        }
    }

    /// The environment a program gets when it is given none: root's home, the usual path, bash as
    /// the shell, and Claude Code's updater off. `SHELL` is what Claude Code's Bash tool runs its
    /// commands in, and `/bin/bash` is where Alpine's bash package installs it
    /// (`RootfsInstaller` lays it in). The binary is a pin the app fetches (`ClaudeCodeInstaller`),
    /// a bump is a new pin, and the updater's own fetch speaks TLS through a library that never
    /// completes a handshake under the emulator. Claude Code's nonessential traffic (telemetry,
    /// error reports, its start-up fetches) is off as well: none of it serves a turn, and a
    /// start under the emulator is about a fifth shorter without it (`docs/perf.md`).
    public static let environment = [
        "HOME": "/root",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "SHELL": "/bin/bash",
        "DISABLE_AUTOUPDATER": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
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

    /// The guest's DNS stub: the one name server `resolv.conf` lists while the app's forwarder is
    /// up. Nothing listens on it; the guest's socket layer carries `127.0.0.53` port 53 to the
    /// forwarder's port (`setDNSPort`) and reports the forwarder's replies as from it.
    public static let dnsStub = "127.0.0.53"

    /// Carries the guest's queries to `dnsStub` to the forwarder at `127.0.0.1:port`, or, with
    /// `nil`, stops carrying them, so the stub is an address nothing answers on
    /// (`patches/ish/0006-dns-sentinel.patch`). Process-wide; needs no booted kernel.
    public func setDNSPort(_ port: UInt16?) {
        topo_ish_set_dns_port(port ?? 0)
    }

    /// The name servers the guest falls back to when the phone lists none the guest can use.
    public static let fallbackNameservers = ["1.1.1.1", "8.8.8.8"]

    /// The name servers the phone's resolver is using now — its network's, or a VPN's while one is
    /// up — as numeric addresses; empty when it lists none or its configuration cannot be read.
    public static func systemNameservers() -> [String] {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard topo_system_nameservers(&buffer, buffer.count) > 0 else { return [] }
        return String(cString: buffer).split(separator: "\n").map(String.init)
    }

    /// The guest's `/etc/resolv.conf` for `servers`: each one that is a numeric IPv4 or IPv6 address
    /// with no scope (a link-local scope names an interface the guest does not have), IPv4 first,
    /// at most three (musl reads no more), or the fallback when none is left.
    public static func resolverFile(for servers: [String]) -> String {
        func isAddress(_ text: String, _ family: Int32) -> Bool {
            var storage = in6_addr()
            return !text.contains("%") && inet_pton(family, text, &storage) == 1
        }
        var seen = Set<String>()
        let usable = servers.filter { seen.insert($0).inserted }
        let chosen = Array((usable.filter { isAddress($0, AF_INET) } + usable.filter { isAddress($0, AF_INET6) })
            .prefix(3))
        return (chosen.isEmpty ? fallbackNameservers : chosen).map { "nameserver \($0)\n" }.joined()
    }

    /// Writes `/etc/resolv.conf` for `servers` (`resolverFile(for:)`), replacing whatever is there,
    /// through the guest so the fakefs records it (a file laid into `data/` from the host has no
    /// metadata, and the guest does not see it). The file is written beside and moved over, so a
    /// lookup never reads half of one. Requires a booted kernel.
    public func writeResolver(servers: [String]) async throws {
        let script = #"printf '%s' "$1" > /etc/resolv.conf.topo && mv -f /etc/resolv.conf.topo /etc/resolv.conf"#
        let exit = try await run("/bin/sh", ["-c", script, "resolver", Self.resolverFile(for: servers)])
        if exit.status != 0 { throw Failure.resolver(exit.errors) }
    }

    /// Empties `/tmp`, as a Linux boot with a tmpfs there would: the guest's `/tmp` is on the
    /// persistent fakefs, so whatever a process killed mid-call left in it — a temporary file its
    /// exit trap never removed — would otherwise outlive the process, the launch and a disconnect.
    /// Run once per process, after the boot and before anything else starts. Requires a booted
    /// kernel.
    public func clearTemporary() async throws {
        let exit = try await run("/bin/sh", ["-c", "find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} +"])
        if exit.status != 0 { throw Failure.temporary(exit.errors) }
    }

    /// Where the guest reaches the phone's zoneinfo: a path no Alpine package owns, so an `apk`
    /// that installs or upgrades tzdata writes its own `/usr/share/zoneinfo` and never meets the mount.
    public static let zoneinfo = "/opt/topo/zoneinfo"

    /// The phone's own time zone database, where Apple's libc reads it (`TZDIR` in its `tzfile.h`):
    /// `/var/db/timezone/zoneinfo` on a device, `/usr/share/zoneinfo` in the simulator. Each is a
    /// link to a versioned directory (`/var/db/timezone/tz/<version>/zoneinfo`), which the mount
    /// resolves and holds.
    public static let hostZoneinfo: String = {
        #if targetEnvironment(simulator)
        "/usr/share/zoneinfo"
        #else
        "/var/db/timezone/zoneinfo"
        #endif
    }()

    /// Mounts the phone's own zoneinfo (`hostZoneinfo`) at `zoneinfo` in the guest, so the guest's
    /// zones are the phone's, with nothing downloaded. The mount is of the versioned directory the
    /// link resolves to when it is made, so a time zone update iOS installs while the process runs
    /// reaches the guest at the next launch. Read-only in effect, not by construction: the mount
    /// is read-write, and the host refuses the app a write there. A refusal to open the directory
    /// throws here. Mounting it again changes nothing. Requires a booted kernel.
    public func mountZoneinfo() throws {
        try mount(URL(fileURLWithPath: Self.hostZoneinfo), at: Self.zoneinfo)
    }

    /// Whether `identifier` is a plain zone name, one that names a file under the zoneinfo and
    /// nothing outside it: components of letters, digits, `_`, `+` and
    /// `-`, apart by `/`, none empty, `.` or `..`, 64 bytes at most.
    public static func isZoneName(_ identifier: String) -> Bool {
        guard identifier.utf8.count <= 64 else { return false }
        return identifier.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+-".unicodeScalars.contains($0)) }
        }
    }

    /// Points the guest's `/etc/localtime` at `<zoneinfo>/<identifier>`, so every program
    /// started after it — BusyBox `date`, musl's `localtime`, and Claude Code's runtime, which takes
    /// the zone's name from where the link points — tells the time in that zone. A link and not a
    /// copy, for that name. Made beside and moved over, through the guest so the fakefs records
    /// it. A name that is not a zone name (`isZoneName`), or one the guest has no zoneinfo for — no
    /// regular file of that name starting with the `TZif` magic (`leapseconds` and `+VERSION` beside
    /// the zones are not ones) under the zoneinfo `mountZoneinfo` mounts — throws and leaves `/etc/localtime` as it was. Requires a booted kernel.
    public func writeTimeZone(identifier: String) async throws {
        guard Self.isZoneName(identifier) else { throw Failure.timeZone("not a zone name: \(identifier)") }
        let script = #"z="$2/$1"; [ -f "$z" ] && [ "$(head -c 4 "$z")" = TZif ] || { echo "no zoneinfo for $1" >&2; exit 1; }; "#
            + #"ln -sfn "$z" /etc/localtime.topo && mv -fT /etc/localtime.topo /etc/localtime"#
        let exit = try await run("/bin/sh", ["-c", script, "zone", identifier, Self.zoneinfo])
        if exit.status != 0 { throw Failure.timeZone(exit.errors) }
    }

    /// Bind-mounts the host directory `host` at `point` in the guest (the fork's realfs), making
    /// `point` a directory first. The guest reads and writes the host's files there, with the
    /// host's mode bits. Mounting the same directory at the same point again changes nothing; a
    /// different one there is refused. Requires a booted kernel.
    public func mount(_ host: URL, at point: String) throws {
        let result = host.withUnsafeFileSystemRepresentation { topo_ish_mount($0, point) }
        if result != 0 { throw Failure.mount(result) }
    }

    /// How long an open or a change in the memory's folder waits for its coordination before
    /// the guest's call fails: the mirror's own bound on a download.
    public static let vaultWait: Duration = .seconds(Int(TOPO_ISH_VAULT_WAIT_SECONDS))

    /// Mounts the memory's folder `host` at `point` through the vault's own filesystem
    /// (`topo_ish_mount_vault`): realfs with every open of a regular file and every change made
    /// under file coordination, each wait bounded, and the mirror's `.topo` at its root hidden.
    /// The same folder at the same point again changes nothing; anything else there is refused.
    /// Requires a booted kernel.
    public func mountVault(_ host: URL, at point: String) throws {
        let result = host.withUnsafeFileSystemRepresentation { topo_ish_mount_vault($0, point) }
        if result != 0 { throw Failure.mount(result) }
    }

    /// Takes away the mount at `point`: refused while anything in the guest holds it, and when
    /// nothing is mounted there. Requires a booted kernel.
    public func unmount(_ point: String) throws {
        let result = topo_ish_unmount(point)
        if result != 0 { throw Failure.unmount(result) }
    }

    /// Makes `path` in the guest a symbolic link to `target`, replacing a link that points
    /// elsewhere and leaving one that already points there untouched. Requires a booted kernel.
    public func link(_ target: String, at path: String) throws {
        let result = topo_ish_link(target, path)
        if result != 0 { throw Failure.link(result, path: path) }
    }

    /// `link` for a command the app puts on the guest's path (`topo`, the shims): the path is the
    /// app's, so a regular file something in the guest left there — a script the mind wrote before
    /// the app had one of its own there — is removed and the link made in its place. A directory
    /// is never removed, and is still refused. Requires a booted kernel.
    public func linkCommand(_ target: String, at path: String) async throws {
        do {
            try link(target, at: path)
        } catch Failure.link(-17, _) {
            let removed = try await run("/bin/sh", ["-c", #"[ -f "$1" ] && [ ! -L "$1" ] && rm -f "$1""#, "sh", path])
            guard removed.status == 0 else { throw Failure.link(-17, path: path) }
            try link(target, at: path)
        }
    }

    /// Runs `path` with `arguments` to its end and returns what it left. The work is blocking —
    /// two pipe reads and a wait on the kernel — so it runs on a queue of its own, never on the
    /// cooperative pool. The reads end when every guest descriptor on the pipes closes, so a
    /// program that leaves a child holding them keeps this waiting for that child too.
    public func run(_ path: String, _ arguments: [String] = [],
                    environment: [String: String] = Guest.environment) async throws -> Exit {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let ran = try Self.runToEnd(path, arguments, environment)
                    return Exit(status: ran.status, output: String(decoding: ran.output, as: UTF8.self),
                                errors: String(decoding: ran.errors, as: UTF8.self))
                })
            }
        }
    }

    /// The longest a file's read may take, in seconds: longer than the vault's own wait for a
    /// coordinated open (`TOPO_ISH_VAULT_WAIT_SECONDS`, 20 s), so a file in the memory that is
    /// slow to come down is read or refused by the vault and not cut off by this.
    public static let readSeconds = 25

    /// The bytes of the regular file the guest sees at `path`, or nil: no such file, something
    /// that is not a regular file (a directory, a pipe, which would hold a read open), one of
    /// more than `limit` bytes, or a read that failed or was ended. The path is the guest's
    /// own, resolved by the guest — its mounts, its links, its permissions — a relative one
    /// against `directory`, so what is read is what a program in the guest reads there and
    /// nothing else: a file in the memory is opened through the vault's filesystem and its
    /// coordination like any guest read.
    ///
    /// It is one short-lived program beside whatever else the guest runs, bounded in bytes
    /// (`head`) and in time (`timeout`, `readSeconds`, with the signal nothing parked in a read
    /// outlasts); nothing here can end it sooner, and a teardown that ends every guest process
    /// ends it too, which is a nil. Each call holds a thread of the shared queue until its
    /// program ends, so a caller with many to make makes them one at a time (`GuestImages`).
    public func contents(ofFile path: String, from directory: String, limit: Int) async throws -> Data? {
        guard !path.isEmpty, !path.utf8.contains(0) else { return nil }
        // A relative path is anchored so that one opening with a dash is a path and no option.
        let named = path.hasPrefix("/") ? path : "./" + path
        let script = #"cd "$1" && [ -f "$2" ] && exec timeout -s KILL "$3" head -c "$4" -- "$2""#
        let arguments = ["-c", script, "sh", directory, named, String(Self.readSeconds), String(limit + 1)]
        let ran: Ran = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runToEnd("/bin/sh", arguments, Guest.environment) })
            }
        }
        guard ran.status == 0, ran.output.count <= limit else { return nil }
        return ran.output
    }

    /// What a program left, as the bytes it wrote.
    private struct Ran: Sendable {
        var status: Int32
        var output: Data
        var errors: Data
    }

    private static func runToEnd(_ path: String, _ arguments: [String], _ environment: [String: String]) throws -> Ran {
        let argv = [path] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var out: Int32 = -1, err: Int32 = -1
        let pid = withCStrings(argv) { argv in
            withCStrings(envp) { envp in topo_ish_spawn(path, argv, envp, nil, &out, &err) }
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
        return Ran(status: status, output: collected.output, errors: collected.errors)
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
func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
    let copies = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } } + [nil]
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
