import Foundation

/// The Claude Code the guest may run: its version, and the size and sha256 of Anthropic's
/// `linux-arm64-musl` build of it, pinned in the app's manifest (`Apps/Topo/Resources/models.json`,
/// the entry `scripts/model-manifest.sh` writes from the release's own `manifest.json`). Nothing
/// else is ever mounted.
public struct ClaudeCodePin: Sendable, Equatable {
    public let version: String
    public let size: Int64
    public let sha256: String

    public init(version: String, size: Int64, sha256: String) {
        self.version = version
        self.size = size
        self.sha256 = sha256
    }
}

/// What the installer reaches the guest through: the guest itself, or a test's counting double.
public protocol GuestMounts: Sendable {
    func mount(_ host: URL, at point: String) throws
    func link(_ target: String, at path: String) throws
}

extension Guest: GuestMounts {}

/// Claude Code in the guest, as one authoritative copy: the file the downloader verified into its
/// manifest home, bind-mounted into the guest at `/opt/claude-code` and reached as
/// `/usr/local/bin/claude`, a link in the fakefs. Nothing is copied, on the first launch or any
/// other, so a relaunch costs a digest and a mount, and a bump is the downloader replacing the
/// file in its home. The binary is checked against the pin — size, then digest, read here whatever
/// checked it before — on every install, and only a file that matches is made executable and
/// mounted; one that does not is made not executable, so no mount this process already made can
/// run it either.
public struct ClaudeCodeInstaller: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongSize(expected: Int64, got: Int64)
        case wrongDigest
        case unreadable(String)

        public var description: String {
            switch self {
            case .wrongSize(let expected, let got): "Claude Code is \(got) bytes, not \(expected)"
            case .wrongDigest: "Claude Code is not the pinned build (digest mismatch)"
            case .unreadable(let why): "Claude Code could not be read: \(why)"
            }
        }
    }

    /// What an install did: the version the guest now runs at `command`, and how long the digest
    /// took, which is what every launch pays in place of a copy.
    public struct Installed: Sendable, Equatable {
        public let version: String
        public let command: String
        public let verification: Duration
    }

    /// Where the binary's home is mounted in the guest.
    public static let mountPoint = "/opt/claude-code"
    /// The name the guest runs it by, a link to the mounted file.
    public static let command = "/usr/local/bin/claude"

    /// The binary on the host, in the downloader's manifest home, which is the directory mounted.
    public let binary: URL
    public let pin: ClaudeCodePin
    public let mountPoint: String
    public let command: String
    let digest: @Sendable (URL) throws -> String

    public init(binary: URL, pin: ClaudeCodePin,
                mountPoint: String = ClaudeCodeInstaller.mountPoint,
                command: String = ClaudeCodeInstaller.command) {
        self.init(binary: binary, pin: pin, mountPoint: mountPoint, command: command, digest: Self.sha256)
    }

    init(binary: URL, pin: ClaudeCodePin, mountPoint: String, command: String,
         digest: @escaping @Sendable (URL) throws -> String) {
        self.binary = binary
        self.pin = pin
        self.mountPoint = mountPoint
        self.command = command
        self.digest = digest
    }

    /// Checks the binary against the pin and, only if it matches, makes it executable, mounts its
    /// home and links `command` to it. Blocking: the digest reads the whole file, so callers run
    /// it off the main thread. Throws, having mounted nothing, when the file is not the pinned
    /// one, and what the guest threw when the mount or the link was refused.
    public func install(into guest: some GuestMounts) throws -> Installed {
        let started = ContinuousClock.now
        do {
            try verify()
        } catch {
            forbidExecution()
            throw error
        }
        let verification = ContinuousClock.now - started
        try allowExecution()
        try guest.mount(binary.deletingLastPathComponent(), at: mountPoint)
        try guest.link("\(mountPoint)/\(binary.lastPathComponent)", at: command)
        return Installed(version: pin.version, command: command, verification: verification)
    }

    func verify() throws {
        let size: Int64
        do {
            size = (try FileManager.default.attributesOfItem(atPath: binary.path)[.size] as? Int64) ?? -1
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard size == pin.size else { throw Failure.wrongSize(expected: pin.size, got: size) }
        guard try digest(binary) == pin.sha256.lowercased() else { throw Failure.wrongDigest }
    }

    /// The guest sees the host's mode bits through the mount, and its kernel refuses to exec a
    /// file no one may execute; the downloader lands every file without the bit.
    private func allowExecution() throws {
        let fm = FileManager.default
        let mode = (try fm.attributesOfItem(atPath: binary.path)[.posixPermissions] as? Int) ?? 0
        if mode & 0o111 != 0o111 {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }

    private func forbidExecution() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
    }

    static func sha256(of url: URL) throws -> String {
        do {
            return try RootfsInstaller.sha256(of: url)
        } catch RootfsInstaller.Failure.unreadable(let why) {
            throw Failure.unreadable(why)
        }
    }
}
