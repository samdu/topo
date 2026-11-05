import AudioToolbox
import AVFoundation
import Foundation
import TopoTools

/// The sound a timer's alert plays in place of the system's (`topo timer --sound`): a file the
/// guest names under its home, copied into the app's `Library/Sounds`, the one folder of the app's
/// own the system plays an alert's sound from, under a name of the alarm's own. It is read through
/// a descriptor opened beneath the home with no link followed anywhere along it, like a widget's
/// image, and judged by what the system plays: an `aiff`, `wav` or `caf` of linear PCM, IMA4,
/// µ-law or a-law under 30 seconds, since anything else the system replaces with its own sound
/// without a word. The copy goes when the alarm does (`TimerRecords.sweep`).
struct TimerSounds: Sendable {
    var home: URL = GuestResident.homeDirectory
    var folder: URL = URL.libraryDirectory.appendingPathComponent("Sounds", isDirectory: true)

    static let guestHome = WidgetTool.guestHome
    static let types = ["caf", "aif", "aiff", "wav"]
    static let bytes = 10 * 1024 * 1024
    static let longest: TimeInterval = 30
    static let formats: Set<AudioFormatID> = [kAudioFormatLinearPCM, kAudioFormatAppleIMA4, kAudioFormatULaw, kAudioFormatALaw]
    static let prefix = "topo-timer-"
    static let partial = ".partial-"

    /// The path's own words: beneath the guest's home, no `.` or `..`, a type the system plays.
    static func judgePath(_ path: String) throws {
        guard path.hasPrefix(guestHome + "/") else { throw ToolFailure("--sound \(path) is not under \(guestHome)", status: ToolReply.usage) }
        let parts = path.dropFirst(guestHome.count).split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw ToolFailure("--sound \(path) names no file, or climbs with . or ..", status: ToolReply.usage)
        }
        guard types.contains((path as NSString).pathExtension.lowercased()) else {
            throw ToolFailure("--sound \(path) is not a .caf, .aiff or .wav", status: ToolReply.usage)
        }
    }

    /// Copies the sound and answers the name the alarm plays it by.
    func copy(_ path: String, for id: UUID) async throws -> String {
        try Self.judgePath(path)
        let name = Self.prefix + id.uuidString.lowercased() + "." + (path as NSString).pathExtension.lowercased()
        let home = home, folder = folder
        try await Task.detached(priority: .userInitiated) {
            let data = try Self.read(path, under: home)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Written and judged under a name of its own first, then moved to the alarm's, which a
            // move refuses to write over: the alarm's name only ever holds a whole, judged copy.
            let partial = folder.appendingPathComponent(Self.partial + name)
            try data.write(to: partial, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            do {
                try Self.judge(partial, path)
                try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(name))
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }.value
        return name
    }

    /// Removes every copy whose alarm AlarmKit no longer lists, by the id in its name, and every
    /// partial copy a killed start left. Called alone (`TimerRecords.alone`), so no copy is in flight.
    func sweep(keeping alarms: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            if name.hasPrefix(Self.partial + Self.prefix) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                continue
            }
            guard name.hasPrefix(Self.prefix) else { continue }
            let id = UUID(uuidString: String((name.dropFirst(Self.prefix.count) as Substring).prefix(36)))
            if let id, alarms.contains(id) { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func remove(_ name: String) {
        guard name.hasPrefix(Self.prefix), !name.contains("/") else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    private static func read(_ path: String, under home: URL) throws -> Data {
        let parts = path.dropFirst(guestHome.count).split(separator: "/")
        let base = open(home.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard base >= 0 else { throw ToolFailure("the guest's home cannot be opened") }
        defer { close(base) }
        // Non-blocking, so a pipe at the name answers at once; the type is judged before a read.
        let file = openat(base, parts.joined(separator: "/"), O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            throw ToolFailure(errno == ELOOP ? "--sound \(path) goes through a link" : "--sound \(path) cannot be opened: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw ToolFailure("--sound \(path) is not a file") }
        guard status.st_size <= bytes else { throw ToolFailure("--sound \(path) is over \(bytes / 1024 / 1024) MB") }
        let data = try handle.read(upToCount: bytes + 1) ?? Data()
        guard data.count <= bytes else { throw ToolFailure("--sound \(path) is over \(bytes / 1024 / 1024) MB") }
        return data
    }

    private static func judge(_ file: URL, _ path: String) throws {
        guard let audio = try? AVAudioFile(forReading: file) else { throw ToolFailure("--sound \(path) is not a sound the phone can read") }
        let format = audio.fileFormat.streamDescription.pointee.mFormatID
        guard formats.contains(format) else {
            throw ToolFailure("--sound \(path) is not linear PCM, IMA4, µ-law or a-law, so the alarm would play the system's sound; convert it to IMA4 or PCM")
        }
        let seconds = Double(audio.length) / audio.fileFormat.sampleRate
        guard seconds.isFinite, seconds > 0, seconds < longest else {
            throw ToolFailure("--sound \(path) runs \(Int(seconds.rounded())) seconds; an alarm plays one under \(Int(longest)), or the system's sound instead")
        }
    }
}
