import Foundation

/// 1Password's CLI, `op`, in the guest: the app's to run with the service-account token only the
/// app holds (`topo secret`). 1Password ships it as a zip, which the downloader verifies into its
/// manifest home at the zip's pin; the guest's own BusyBox `unzip` extracts `op` from it into a
/// directory of its own outside the downloader's homes (whose sweep removes anything that is not a
/// manifest file), and the binary is checked against its own pin — size, then digest — on every
/// install before it is made executable and mounted, and again before every run (`check`), since
/// the guest can write the directory it is mounted from. One that does not match is made not
/// executable, so no token is handed to a binary nobody pinned. It is not linked onto the guest's
/// path: the mind can see the file, and without the token it is inert.
public struct OnePasswordInstaller: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongSize(expected: Int64, got: Int64)
        case wrongDigest
        case unreadable(String)
        case extraction(String)

        public var description: String {
            switch self {
            case .wrongSize(let expected, let got): "op is \(got) bytes, not \(expected)"
            case .wrongDigest: "op is not the pinned build (digest mismatch)"
            case .unreadable(let why): "op could not be read: \(why)"
            case .extraction(let why): "op could not be extracted from its zip: \(why)"
            }
        }
    }

    /// Where the extracted binary's directory is mounted, and so what the app runs.
    public static let mountPoint = "/opt/op-cli"
    public static let command = mountPoint + "/op"
    /// Where the zip's home is mounted while `op` is extracted.
    public static let zipMountPoint = "/opt/op-cli-zip"

    /// The downloaded zip, in its manifest home.
    public let zip: URL
    /// The directory `op` is extracted into and mounted from.
    public let directory: URL
    /// The pin of the `op` inside the zip.
    public let pin: ClaudeCodePin
    let digest: @Sendable (URL) throws -> String

    public init(zip: URL, directory: URL, pin: ClaudeCodePin) {
        self.init(zip: zip, directory: directory, pin: pin, digest: { try RootfsInstaller.sha256(of: $0) })
    }

    init(zip: URL, directory: URL, pin: ClaudeCodePin, digest: @escaping @Sendable (URL) throws -> String) {
        self.zip = zip
        self.directory = directory
        self.pin = pin
        self.digest = digest
    }

    var binary: URL { directory.appendingPathComponent("op") }

    /// The guest command that extracts `op` from the zip into the mounted directory.
    public var extraction: String {
        "unzip -o -q '\(Self.zipMountPoint)/\(zip.lastPathComponent)' op -d '\(Self.mountPoint)'"
    }

    /// The first half of an install into a booted guest: mounts the directory `op` lives in and,
    /// when it holds no binary at its pin, the zip's home too, answering whether `extraction` has
    /// to run in the guest before `complete`. Blocking (a digest of the whole binary), so callers
    /// run it off the main thread and off the cooperative pool.
    public func mount(into guest: some GuestMounts) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try guest.mount(directory, at: Self.mountPoint)
        if (try? verify()) != nil { return false }
        forbidExecution()
        try guest.mount(zip.deletingLastPathComponent(), at: Self.zipMountPoint)
        return true
    }

    /// The second half: given how the extraction went, if it ran, checks the binary against its
    /// pin and only then makes it executable. Blocking, as `mount` is.
    public func complete(extracted: (status: Int32, errors: String)?) throws {
        if let extracted, extracted.status != 0 {
            throw Failure.extraction(extracted.errors.isEmpty ? "status \(extracted.status)" : extracted.errors)
        }
        do {
            try verify()
        } catch {
            forbidExecution()
            throw error
        }
        try allowExecution()
    }

    /// The binary checked against its pin before a run: one that does not match is made not
    /// executable, so it is never run with the token. Blocking, as `mount` is.
    public func check() throws {
        do {
            try verify()
        } catch {
            forbidExecution()
            throw error
        }
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

    private func allowExecution() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    private func forbidExecution() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
    }
}
