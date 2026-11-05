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
            let target = folder.appendingPathComponent(name)
            try data.write(to: target, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            do {
                try Self.judge(target, path)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }.value
        return name
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
