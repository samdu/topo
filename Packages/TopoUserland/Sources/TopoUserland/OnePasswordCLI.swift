import Foundation

/// 1Password's CLI, `op`, in the guest: the app's to run with the service-account token only the
/// app holds (`topo secret`). 1Password ships it as a zip, which the downloader verifies into its
/// manifest home at the zip's pin; the guest's own BusyBox `unzip` extracts `op` from it into a
/// directory of its own outside the downloader's homes (whose sweep removes anything that is not a
/// manifest file), and the binary is checked against its own pin — size, then digest — on every
/// install before it is made executable and mounted, so what the app downloaded is the build it
/// pinned. That is a check of the download and not a bound on the guest: the guest can write the
/// directory `op` is mounted from, unmount it, or replace what `op`'s script runs, and so can obtain
/// the token (`docs/guest.md`). It is not linked onto the guest's path.
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

/// One run of `op` with the service-account token, in the guest: the token only in that process's
/// environment (never an argument, so no `/proc/<pid>/cmdline` holds it), `OP_CACHE=false`, and
/// `OP_CONFIG_DIR` and `TMPDIR` a directory made for the call and removed after it. `op` starts a
/// daemon of its own whether or not caching is off — `op daemon`, in a session of its own,
/// reparented to init, carrying the token in its environment — and writes its pid under
/// `TMPDIR`, so when `op` returns the script ends that pid, its session and its children, then
/// every other process of its own process group: the watcher that bounds `op` at 60 s, and anything `op`
/// started without leaving it. A cancelled run does the same from outside, through the file the
/// script wrote its group id to, and removes the directory kept beside that file. Nothing is
/// matched by name.
public enum OnePasswordRun {
    /// The whole of what the guest runs: `$@` is `op`'s arguments, `$TOPO_OP_GROUP` the file the
    /// group id is written to, and `$TOPO_OP_GROUP.d` the call's directory.
    public static func script(command: String) -> String {
        #"""
        stat="$(cat /proc/$$/stat)" || exit 70
        rest="${stat##*) }"
        group="$(echo $rest | cut -d ' ' -f 3)"
        [ -n "$group" ] || exit 70
        printf '%s\n' "$group" > "$TOPO_OP_GROUP" || exit 70
        d="$TOPO_OP_GROUP.d"
        mkdir -m 700 "$d" || exit 70
        OP_CONFIG_DIR="$d" TMPDIR="$d" \#(command) "$@" &
        op=$!
        ( sleep 60; kill -KILL "$op" ) 2>/dev/null &
        wait "$op"
        s=$?
        \#(end)
        rm -rf "$d" "$TOPO_OP_GROUP"
        exit $s
        """#
    }

    /// Ends the daemon whose pid `op` writes under `$d` — waiting up to 5 s for the file once its
    /// directory is there, since `op` can return before the daemon has written it — with every
    /// process in the daemon's session and each one it is the parent of, then every process in
    /// process group `$group` but the shell running this: a sweep of `/proc` by each task's `stat`.
    static let end = #"""
    for f in "$d"/com.agilebits.op.*/op-daemon.pid; do
        [ -e "$f" ] || break
        i=0
        while [ ! -s "$f" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    done
    daemon="$(cat "$d"/com.agilebits.op.*/op-daemon.pid 2>/dev/null)"
    session=""
    if [ -n "$daemon" ] && stat="$(cat "/proc/$daemon/stat" 2>/dev/null)"; then
        session="$(echo ${stat##*) } | cut -d ' ' -f 4)"
    fi
    for task in /proc/[0-9]*; do
        pid=${task#/proc/}
        [ "$pid" = "$$" ] || [ "$pid" = 1 ] && continue
        stat="$(cat "$task/stat" 2>/dev/null)" || continue
        rest="$(echo ${stat##*) } | cut -d ' ' -f 2-4)"
        parent=${rest%% *}
        taskSession=${rest##* }
        taskGroup=${rest#* }
        taskGroup=${taskGroup% *}
        if [ "$taskGroup" = "$group" ] || [ -n "$session" -a "$taskSession" = "$session" ] \
            || [ -n "$daemon" -a "$parent" = "$daemon" ]; then
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    [ -n "$daemon" ] && kill -KILL "$daemon" 2>/dev/null
    """#

    /// What a cancelled run runs beside it: the group id the run wrote, the same ending, and the
    /// run's directory removed.
    static let cancel = #"""
    group="$(cat "$1" 2>/dev/null)" || exit 0
    [ -n "$group" ] || exit 0
    d="$1.d"
    """# + "\n" + end + "\n" + #"rm -rf "$1" "$d""#

    public static func run(_ arguments: [String], token: String, command: String = OnePasswordInstaller.command,
                           guest: Guest = .shared) async throws -> Guest.Exit {
        let groupFile = "/tmp/topo-op-\(UUID().uuidString).group"
        var environment = Guest.environment
        environment["OP_SERVICE_ACCOUNT_TOKEN"] = token
        environment["OP_CACHE"] = "false"
        environment["TOPO_OP_GROUP"] = groupFile
        return try await withTaskCancellationHandler {
            try await guest.run("/bin/sh", ["-c", script(command: command), "op"] + arguments, environment: environment)
        } onCancel: {
            Task.detached { _ = try? await guest.run("/bin/sh", ["-c", cancel, "cancel", groupFile]) }
        }
    }
}
