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

    /// Writes `data` at `folders`/`name` under `home`, making the folders that are not there. It is
    /// written under a hidden name and given its own with a hard link, so the name never holds
    /// half a file, and the link is made only where nothing is. A `locked` file is given complete
    /// protection before a byte of it is written, so it cannot be read while the phone is locked.
    static func create(_ data: Data, named name: String, in folders: [String], under home: URL, locked: Bool = false) throws -> Outcome {
        guard plain(name) else { throw ToolFailure("\(name) is not a file's name") }
        let folder = try open(folders, under: home, making: true)
        defer { close(folder) }
        let part = ".\(UUID().uuidString).part"
        let file = openat(folder, part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else {
            throw ToolFailure("\(name) could not be made in the guest's home: \(String(cString: strerror(errno)))")
        }
        defer { _ = unlinkat(folder, part, 0) }
        guard !locked || lock(file) else {
            let failure = errno
            close(file)
            throw ToolFailure("\(name) could not be protected in the guest's home: \(String(cString: strerror(failure)))")
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
        var failure = errno
        close(file)
        guard wrote else {
            throw ToolFailure("\(name) could not be written in the guest's home: \(String(cString: strerror(failure)))")
        }
        guard linkat(folder, part, folder, name, 0) == 0 else {
            failure = errno
            if failure == EEXIST { return .exists }
            throw ToolFailure("\(name) could not be made in the guest's home: \(String(cString: strerror(failure)))")
        }
        return .created
    }

    /// Takes away the file `create` made at `folders`/`name`. A file that is not there is left so.
    static func remove(named name: String, in folders: [String], under home: URL) {
        guard plain(name), let folder = try? open(folders, under: home, making: false) else { return }
        defer { close(folder) }
        _ = unlinkat(folder, name, 0)
    }

    /// Takes away every regular file in `folders` last written more than `age` ago: what a call
    /// the app was killed under left there. Only for a folder that holds nothing but the app's own.
    static func clear(_ folders: [String], under home: URL, olderThan age: TimeInterval) {
        guard let folder = try? open(folders, under: home, making: false) else { return }
        // The stream closes the descriptor it is given.
        guard let stream = fdopendir(folder) else { close(folder); return }
        defer { closedir(stream) }
        let cutoff = time(nil) - Int(age)
        var stale: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            var status = stat()
            guard fstatat(dirfd(stream), name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & S_IFMT == S_IFREG, status.st_mtimespec.tv_sec < cutoff else { continue }
            stale.append(name)
        }
        for name in stale { _ = unlinkat(dirfd(stream), name, 0) }
    }

    /// The protection class of an open file: 1 is complete protection, 0 a volume that keeps none.
    static func protection(of file: Int32) -> Int32 {
        fcntl(file, F_GETPROTECTIONCLASS)
    }

    private static func lock(_ file: Int32) -> Bool {
        fcntl(file, F_SETPROTECTIONCLASS, 1) == 0
    }

    /// One name, and no path: nothing here walks further than the folders it was given.
    private static func plain(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
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
