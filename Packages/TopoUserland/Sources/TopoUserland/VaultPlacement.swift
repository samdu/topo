import Foundation

/// A file the app hands the guest to put in the memory's folder: a short program in the guest
/// copies it there, so the folder has no writer but the vault's own filesystem, with its
/// coordination, its bound and its refusal of `.topo`.
public enum VaultPlacement {
    public enum Outcome: Sendable, Equatable {
        /// The file is at its name, and this many bytes.
        case placed(bytes: Int)
        /// Something is at that name already; nothing was written.
        case exists
        /// No memory's folder is mounted at the root.
        case unmounted
        /// The folder could not be made.
        case noFolder
        /// The copy was not done by `deadline`, so nothing was given the name.
        case late
        case failed
    }

    /// The longest the copy itself may take, in seconds.
    public static let copySeconds = 20

    /// Copies `$1` to `$2/$3/$4` under a hidden name the mirror does not read, then gives it its
    /// name with a hard link, which the filesystem makes only where nothing is: a copy cut short
    /// leaves no half a file under the name, and a file that arrived at the name meanwhile, from
    /// the mirror or another device, is not written over. The name is given only before `$6`
    /// (seconds since 1970). `$2` is where a vault is mounted (`/proc/mounts`, read from the end of
    /// its line, since the host's path opens it) or nothing is done: after an unmount the path is a
    /// bare folder, and a link to the mount, as the home's `memory` is, is not the mount. The
    /// program removes its own hidden copy as it ends and nothing else, ever: a name cannot say who
    /// made a file, so a copy left by a program that was killed stays, hidden, where the mirror
    /// does not read it. Prints the size of what landed, read without an open, which would
    /// wait on the file's coordination again.
    static let script = #"""
    root="$2"; dir="$2/$3"; dst="$dir/$4"; tmp="$dir/.topo-pick-$$.part"
    awk -v at="$root" '$(NF-4) == at && $(NF-3) == "topo-vault" { vault = 1 } END { exit !vault }' /proc/mounts || exit 20
    mkdir -p -- "$dir" || exit 21
    trap 'rm -f -- "$tmp"' EXIT
    [ -e "$dst" ] || [ -L "$dst" ] && exit 17
    timeout -s KILL "$5" cp -- "$1" "$tmp" || exit 22
    [ "$(date +%s)" -lt "$6" ] || exit 24
    if ln -- "$tmp" "$dst" 2>/dev/null; then stat -c %s -- "$dst"; exit 0; fi
    [ -e "$dst" ] || [ -L "$dst" ] && exit 17
    exit 23
    """#

    /// Puts the guest's file `source` at `folder`/`name` under the vault mounted at `root`, the
    /// memory's own mount unless another is named, where nothing is yet. The name is given no later than one vault wait (`Guest.vaultWait`) after
    /// `deadline`; a caller with a bound of its own passes a deadline that far inside it.
    /// Requires a booted kernel.
    public static func place(_ source: String, at root: String = ClaudeLauncher.vault, folder: String, name: String,
                             by deadline: Date, in guest: Guest = .shared) async throws -> Outcome {
        let ran = try await guest.run("/bin/sh", ["-c", script, "sh", source, root, folder, name, String(copySeconds),
                                                  String(Int(deadline.timeIntervalSince1970))])
        switch ran.status {
        case 0:
            // The size is read back, since a program that hung can answer 0 with nothing said.
            guard let bytes = Int(ran.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .failed }
            return .placed(bytes: bytes)
        case 17: return .exists
        case 20: return .unmounted
        case 21: return .noFolder
        case 24: return .late
        default: return .failed
        }
    }
}
