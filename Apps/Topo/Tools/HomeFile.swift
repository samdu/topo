import Foundation

/// A file the app itself writes into the guest's home, for the mind to read there: made through a
/// descriptor walked down from the home one name at a time with no link followed, so a link the
/// guest has put in its home can send the app's write nowhere outside it, and created only where
/// nothing is, so nothing of the guest's is written over.
enum HomeFile {
    enum Outcome: Equatable {
        case created
        /// Something is at that name already; nothing was written.
        case exists
    }

    /// Writes `data` at `folders`/`name` under `home`, making the folders that are not there.
    static func create(_ data: Data, named name: String, in folders: [String], under home: URL) throws -> Outcome {
        let folder = try open(folders, under: home, making: true)
        defer { close(folder) }
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else {
            if errno == EEXIST { return .exists }
            throw ToolFailure("\(name) could not be made in the guest's home: \(String(cString: strerror(errno)))")
        }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var written = 0
            while written < buffer.count {
                let count = write(file, buffer.baseAddress?.advanced(by: written), buffer.count - written)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        let failure = errno
        close(file)
        guard wrote else {
            _ = unlinkat(folder, name, 0)
            throw ToolFailure("\(name) could not be written in the guest's home: \(String(cString: strerror(failure)))")
        }
        return .created
    }

    /// Takes away the file `create` made at `folders`/`name`. A file that is not there is left so.
    static func remove(named name: String, in folders: [String], under home: URL) {
        guard let folder = try? open(folders, under: home, making: false) else { return }
        defer { close(folder) }
        _ = unlinkat(folder, name, 0)
    }

    private static func open(_ folders: [String], under home: URL, making: Bool) throws -> Int32 {
        var folder = Darwin.open(home.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw ToolFailure("the guest's home cannot be opened") }
        for name in folders {
            if making { _ = mkdirat(folder, name, 0o755) }
            let next = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            close(folder)
            guard next >= 0 else {
                throw ToolFailure(failure == ELOOP || failure == ENOTDIR
                    ? "\(name) in the guest's home is not a folder" : "\(name) in the guest's home cannot be opened: \(String(cString: strerror(failure)))")
            }
            folder = next
        }
        return folder
    }
}
