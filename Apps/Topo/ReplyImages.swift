import Foundation

/// The bytes of an image a reply names, read from the guest's own home and from nowhere else.
///
/// The home is the app's `Documents/home` (`GuestResident.homeDirectory`), which the guest sees
/// as `/home/topo`. A reply names a file by its path from there (`Markdown.place(ofImage:)` has
/// already refused an absolute path, one that climbs, the memory and every URL), and the file is
/// opened beneath the home's own descriptor with no link followed at any component
/// (`O_NOFOLLOW_ANY`): the home's `memory` is a link to the vault, and a link the guest makes
/// could name anything the app can open, so a path through either reaches nothing. Only a
/// regular file is read, and only up to `limit` bytes. The vault is not read here at all: that
/// folder is shared and coordinated (`VaultMirror`), and a picture is never a reason to open it.
enum ReplyImages {
    /// The most bytes an image file may be. A chart or a photograph is well under it; past it
    /// the file is not read at all.
    static let limit = 8 * 1024 * 1024

    /// The reader the chat hands its replies (`EnvironmentValues.replyImage`).
    static let read: @Sendable (String) -> Data? = { path in bytes(at: path, under: GuestResident.homeDirectory) }

    /// The file at `path` — relative, with no `.` or `..` in it — beneath `home`, or nil: no
    /// such file, a link anywhere along the way, something that is not a regular file, or one
    /// over the limit.
    static func bytes(at path: String, under home: URL, limit: Int = ReplyImages.limit) -> Data? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        // The home itself is opened as what it is: a link standing where the home should be is
        // refused like any other.
        let base = open(home.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { return nil }
        defer { close(base) }
        let file = openat(base, parts.joined(separator: "/"), O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= limit else { return nil }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}
