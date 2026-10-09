#if os(iOS)
import Foundation

/// One thing the person shared with Topo from another app's share sheet: what it is, what they
/// wrote about it, and never a turn's text, which the app writes when it puts the share on the
/// line (`ShareInbox`).
struct Share: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text, link, image, file
    }

    /// The nonce the share's turn goes under, minted by the extension, so a share drained twice
    /// is one turn.
    var nonce: String
    var time: Date
    var kind: Kind
    /// What the person wrote in the sheet. Empty when they wrote nothing.
    var note: String
    /// The shared text, or the link.
    var text: String?
    /// The name of the image or file kept beside the record.
    var file: String?
    var bytes: Int?

    /// The longest note, in characters.
    static let noteLimit = 4000
    /// The most shared text or the longest link, in UTF-8 bytes.
    static let textLimit = 64 * 1024
    /// The largest image or file, the same line `topo files pick` draws.
    static let fileLimit = 20 * 1024 * 1024
    /// The longest name a shared file is kept under, in UTF-8 bytes.
    static let nameBytes = 200

    /// The name a shared file is kept under: its own last component with nothing that would make
    /// it a path or a hidden name, cut to `nameBytes` with its extension kept.
    static func name(_ suggested: String) -> String {
        var name = String(suggested.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        name = String(name.drop { $0 == "." || $0 == " " })
        if name.isEmpty { name = "shared" }
        guard name.utf8.count > nameBytes else { return name }
        let whole = name as NSString
        var ending = whole.pathExtension.isEmpty ? "" : "." + whole.pathExtension
        if ending.utf8.count > nameBytes / 2 { ending = "" }
        var stem = ending.isEmpty ? name : whole.deletingPathExtension
        while stem.utf8.count + ending.utf8.count > nameBytes { stem.removeLast() }
        return stem.isEmpty ? "shared" + ending : stem + ending
    }
}

/// Why a share was not kept, in words the sheet shows the person.
enum ShareRefusal: Error, Equatable {
    case signedOut
    case anotherPhone
    case nothing
    case tooLarge
    case tooLong
    case tooMany
    case failed

    var words: String {
        switch self {
        case .signedOut: "Open Topo and sign in first."
        case .anotherPhone: "An image or a file can only be shared on the phone Topo lives on."
        case .nothing: "There is nothing here Topo can take."
        case .tooLarge: "That is larger than Topo takes (20 MB)."
        case .tooLong: "That is more text than Topo takes at once."
        case .tooMany: "Topo is holding as many shares as it can. Open Topo so it can read them."
        case .failed: "Topo could not keep that."
        }
    }
}

/// What the person has shared and the app has not yet put on the line: the `Shares` folder in the
/// app group, which the share extension writes and the app reads and empties.
///
/// - `_open.json`, there while this phone is signed in, saying whether it takes images and files
///   (it does where the guest lives). The extension keeps nothing without it;
/// - `<nonce>/share.json`, one share's record, and beside it the image or file it names;
/// - `.<name>/`, a share being written or an attachment being read, which no reader lists.
///
/// A share is written whole under a hidden name and renamed to its nonce, so the app never reads
/// half of one. A sign-out takes the folder away: a share is never kept for the next login.
struct ShareStore: Sendable {
    static let appGroup = "group.zone.hexagon.topo"
    /// The most shares held at once.
    static let held = 16
    static let record = "share.json"

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// The app group's folder, or nil where the process has no app group (an unsigned build).
    static func shared() -> ShareStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ShareStore(folder: $0.appendingPathComponent("Shares", isDirectory: true)) }
    }

    /// What the signed-in phone takes.
    struct Door: Codable, Equatable, Sendable {
        /// Images and files, which need the guest's home to be on this phone.
        var files: Bool
    }

    private var doorURL: URL { folder.appendingPathComponent("_open.json") }

    /// Signed in: shares are taken from now on.
    func open(files: Bool) throws {
        try make(folder)
        let door = try JSONEncoder().encode(Door(files: files))
        if (try? Data(contentsOf: doorURL)) != door {
            try door.write(to: doorURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Signed out: nothing is taken, and nothing shared is kept.
    func close() {
        try? FileManager.default.removeItem(at: folder)
    }

    func door() -> Door? {
        (try? Data(contentsOf: doorURL)).flatMap { try? JSONDecoder().decode(Door.self, from: $0) }
    }

    /// A folder for an attachment being read out of another app, which `keep` moves the file out
    /// of and `discard` takes away.
    func scratch() throws -> URL {
        let scratch = folder.appendingPathComponent(".intake-\(UUID().uuidString)", isDirectory: true)
        try make(scratch)
        return scratch
    }

    func discard(_ scratch: URL) {
        guard scratch.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              scratch.lastPathComponent.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Keeps a share, moving `attachment` in beside its record under the name the share gives it.
    /// Refused, with nothing kept, when signed out, when it is an image or a file and this is not
    /// the guest's phone, when it is over a limit, or when `held` shares are waiting.
    func keep(_ share: Share, attachment: URL? = nil) throws(ShareRefusal) {
        guard let door = door() else { throw .signedOut }
        guard share.note.count <= Share.noteLimit, (share.text?.utf8.count ?? 0) <= Share.textLimit else { throw .tooLong }
        switch share.kind {
        case .text, .link:
            guard attachment == nil, share.file == nil, share.text?.isEmpty == false else { throw .nothing }
        case .image, .file:
            guard door.files else { throw .anotherPhone }
            guard let attachment, let name = share.file, name == Share.name(name),
                  let bytes = Self.size(of: attachment), bytes == share.bytes else { throw .nothing }
            guard bytes <= Share.fileLimit else { throw .tooLarge }
        }
        guard UUID(uuidString: share.nonce) != nil else { throw .failed }
        guard shares().count < Self.held else { throw .tooMany }
        let staging = folder.appendingPathComponent(".\(share.nonce)", isDirectory: true)
        do {
            try make(staging)
            if let attachment, let name = share.file {
                try FileManager.default.moveItem(at: attachment, to: staging.appendingPathComponent(name))
            }
            try JSONEncoder().encode(share)
                .write(to: staging.appendingPathComponent(Self.record), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.moveItem(at: staging, to: folder.appendingPathComponent(share.nonce, isDirectory: true))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw .failed
        }
    }

    /// Every share kept, oldest first. A folder with no record that reads is not one.
    func shares() -> [Share] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }
            .compactMap { name -> Share? in
                let url = folder.appendingPathComponent(name).appendingPathComponent(Self.record)
                guard let share = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(Share.self, from: $0) }),
                      share.nonce == name else { return nil }
                return share
            }
            .sorted { ($0.time, $0.nonce) < ($1.time, $1.nonce) }
    }

    /// Where a kept share's image or file is.
    func attachment(of share: Share) -> URL? {
        guard let name = share.file, name == Share.name(name), UUID(uuidString: share.nonce) != nil else { return nil }
        return folder.appendingPathComponent(share.nonce).appendingPathComponent(name)
    }

    func remove(nonce: String) {
        guard UUID(uuidString: nonce) != nil else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(nonce))
    }

    /// Takes away what a sheet that was killed left half made: a hidden folder older than `age`.
    func clearUnfinished(olderThan age: TimeInterval, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            guard let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(made) > age else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func size(of file: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue
    }

    private func make(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
    }
}
#endif
