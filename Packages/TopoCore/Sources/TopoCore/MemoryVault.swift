import Foundation

/// Where a note sits in the vault: a relative path of one or more
/// components, the way a link inside an Obsidian vault is written.
///
/// Absolute paths, `.` and `..`, and empty components are not paths in a
/// vault. Neither is anything hidden: a component beginning with a dot is
/// refused, which keeps a vault's local-only folders — Obsidian's own
/// `.obsidian`, the mirror's `.topo` — out of the store.
public struct VaultPath: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let components: [String]

    public var string: String { components.joined(separator: "/") }
    public var description: String { string }
    /// The last component: the file's name with its extension.
    public var name: String { components[components.count - 1] }

    public init?(_ string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty, !part.hasPrefix("."),
                  !part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        }
        components = parts
    }

    init(checked components: [String]) { self.components = components }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let path = VaultPath(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a vault path: \(string)"))
        }
        self = path
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    /// The name without its extension, and the extension with its dot. A
    /// name that is nothing but an extension (`.gitignore`) cannot be a
    /// vault path, so the dot is never the first character here.
    var stemAndExtension: (stem: String, extension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// The same folder, a different name.
    func sibling(named name: String) -> VaultPath {
        VaultPath(checked: components.dropLast() + [name])
    }

    public static func < (a: VaultPath, b: VaultPath) -> Bool {
        a.components.lexicographicallyPrecedes(b.components)
    }
}

/// Names one revision of one note: the device that wrote it and its
/// sequence number on that device. Sequence numbers start at 1.
public struct NoteRef: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let device: DeviceID
    public let sequence: Int64

    public init(device: DeviceID, sequence: Int64) {
        self.device = device
        self.sequence = sequence
    }

    public var description: String { "\(device.rawValue)/\(sequence)" }

    public static func < (a: NoteRef, b: NoteRef) -> Bool {
        (a.device.rawValue, a.sequence) < (b.device.rawValue, b.sequence)
    }

    /// Parses the form `device/sequence`. The device may itself contain slashes.
    public init?(parsing string: String) {
        guard let slash = string.lastIndex(of: "/"),
              let sequence = Int64(string[string.index(after: slash)...]) else { return nil }
        self.init(device: DeviceID(String(string[..<slash])), sequence: sequence)
    }
}

/// One revision of one note. Immutable once written; a change to a note is
/// a new revision naming the revisions it replaces.
///
/// A deletion is a revision like any other, with no text: the vault is
/// append-only, so a file that goes away leaves a revision saying so, and a
/// delete on one device cannot silently swallow an edit made on another.
public struct Note: Hashable, Sendable, Identifiable {
    public static let recordType = "Note"
    static let recordPrefix = "note/"
    static let naming = RecordNaming(prefix: recordPrefix, markerType: "NoteWrite",
                                     markerPrefix: "notewrite/", markerField: "note")

    public let ref: NoteRef
    public let path: VaultPath
    public let text: String
    public let isDeleted: Bool
    /// The revisions of this path this one replaces: the heads the writer
    /// saw. More than one means this revision resolves a fork.
    public let parents: [NoteRef]
    public let at: Date
    /// Marks the write that made this revision, so a retry after a lost
    /// acknowledgement finds it rather than writing it twice.
    public let nonce: String

    public var id: NoteRef { ref }

    public init(ref: NoteRef, path: VaultPath, text: String, isDeleted: Bool = false,
                parents: [NoteRef], at: Date, nonce: String = UUID().uuidString) {
        self.ref = ref
        self.path = path
        self.text = isDeleted ? "" : text
        self.isDeleted = isDeleted
        self.parents = parents
        self.at = at
        self.nonce = nonce
    }

    public static func recordID(for ref: NoteRef) -> RecordID {
        naming.recordID(ref.device, ref.sequence)
    }

    /// The ref a note record's name carries, whatever the rest of it holds.
    static func ref(ofRecordNamed name: String) -> NoteRef? {
        guard name.hasPrefix(recordPrefix) else { return nil }
        return NoteRef(parsing: String(name.dropFirst(recordPrefix.count)))
    }

    /// The record for a new revision. Its tag is nil: the save is create-only.
    var record: Record {
        Record(type: Note.recordType, id: Note.recordID(for: ref), fields: [
            "device": .string(ref.device.rawValue),
            "sequence": .int(ref.sequence),
            "path": .string(path.string),
            "text": .string(text),
            "deleted": .int(isDeleted ? 1 : 0),
            "parents": .strings(parents.map(\.description)),
            "at": .date(at),
            "nonce": .string(nonce),
        ])
    }

    /// Nil if the record is not a well-formed revision. An absent `parents`
    /// field reads as no parents, since CloudKit may drop an empty list, an
    /// absent `deleted` field reads as not deleted, and an absent `nonce`
    /// reads as empty, so a record written without one still reads as a
    /// revision and is nobody's retry.
    public init?(record: Record) {
        guard record.type == Note.recordType,
              let device = record.string("device"),
              let sequence = record.int("sequence"), sequence >= 1,
              let pathString = record.string("path"), let path = VaultPath(pathString),
              let text = record.string("text"),
              let at = record.date("at") else { return nil }
        let parentStrings = record.strings("parents") ?? []
        let parents = parentStrings.compactMap(NoteRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.init(ref: NoteRef(device: DeviceID(device), sequence: sequence), path: path, text: text,
                  isDeleted: (record.int("deleted") ?? 0) != 0, parents: parents, at: at,
                  nonce: record.string("nonce") ?? "")
    }
}

/// One file as the vault presents it: the winning revision of a path, or a
/// conflict copy of a revision that lost.
public struct VaultFile: Hashable, Sendable {
    /// Where the file appears. A conflict copy appears beside the path it
    /// is a copy of, under a name of its own.
    public let path: VaultPath
    /// The path this file is a revision of. The same as `path` unless it is
    /// a conflict copy.
    public let origin: VaultPath
    public let text: String
    public let at: Date
    /// The revision this file holds.
    public let head: NoteRef

    public var isConflictCopy: Bool { path != origin }
}

/// The memory as read: every revision, and the files they resolve to.
///
/// Two devices that edit the same path without seeing each other's edit
/// leave two heads. Neither is thrown away: the newer one is the file, and
/// each older one appears beside it as a conflict copy, named the way
/// Obsidian names one. Editing the file resolves the fork, because a write
/// continues from every head the writer saw.
///
/// A vault is complete when every revision it needs is present. An
/// incomplete one has revisions the reader could not see — a record the
/// query index has not caught up with, or one that does not parse — so its
/// heads may name a fork that never happened and nothing is written from it.
public struct Vault: Sendable {
    /// Every revision read, by ref.
    public let notes: [NoteRef: Note]
    /// The vault as files, conflict copies included.
    public let files: [VaultPath: VaultFile]
    /// Refs the store must hold and this read did not.
    public let missing: Set<NoteRef>
    /// Records of the note type whose name is not a ref. Nothing can be
    /// said about them.
    public let unreadable: [RecordID]

    private let headsByPath: [VaultPath: [NoteRef]]

    public init(notes: [Note], missing: Set<NoteRef> = [], unreadable: [RecordID] = []) {
        var byRef: [NoteRef: Note] = [:]
        for note in notes { byRef[note.ref] = note }

        var missing = missing
        var lastSeen: [DeviceID: Int64] = [:]
        for note in byRef.values {
            for parent in note.parents where byRef[parent] == nil { missing.insert(parent) }
            lastSeen[note.ref.device] = max(lastSeen[note.ref.device] ?? 0, note.ref.sequence)
        }
        for (device, last) in lastSeen where last >= 1 {
            for sequence in 1...last where byRef[NoteRef(device: device, sequence: sequence)] == nil {
                missing.insert(NoteRef(device: device, sequence: sequence))
            }
        }

        var byPath: [VaultPath: [Note]] = [:]
        for note in byRef.values { byPath[note.path, default: []].append(note) }

        var heads: [VaultPath: [NoteRef]] = [:]
        var files: [VaultPath: VaultFile] = [:]
        var losers: [(origin: VaultPath, note: Note)] = []
        for (path, revisions) in byPath {
            let refs = Set(revisions.map(\.ref))
            let replaced = Set(revisions.flatMap(\.parents)).intersection(refs)
            let pathHeads = revisions.filter { !replaced.contains($0.ref) }
            heads[path] = pathHeads.map(\.ref).sorted()

            // The same content twice is not a conflict: a write retried
            // after a lost acknowledgement, or the same edit made on two
            // devices, leaves two heads saying the same thing.
            var byContent: [String: Note] = [:]
            for head in pathHeads {
                let key = (head.isDeleted ? "1\u{0}" : "0\u{0}") + head.text
                if let kept = byContent[key], Self.newer(kept, than: head) { continue }
                byContent[key] = head
            }
            let ordered = byContent.values.sorted { Self.newer($0, than: $1) }
            guard let winner = ordered.first else { continue }
            if !winner.isDeleted {
                files[path] = VaultFile(path: path, origin: path, text: winner.text, at: winner.at, head: winner.ref)
            }
            // A losing deletion leaves nothing behind: there is no content
            // to keep a copy of, and the file it would have removed is
            // already here.
            for loser in ordered.dropFirst() where !loser.isDeleted {
                losers.append((path, loser))
            }
        }

        for (origin, loser) in losers.sorted(by: { $0.note.ref < $1.note.ref }) {
            let path = Self.conflictCopyPath(of: origin, for: loser, avoiding: files.keys)
            files[path] = VaultFile(path: path, origin: origin, text: loser.text, at: loser.at, head: loser.ref)
        }

        // A path cannot be both a file and a folder. Two devices can write
        // `notes` and `notes/today.md` without either being wrong, and both
        // revisions are kept — but a folder of markdown has to hold them,
        // so the one standing where the folder goes is shown beside it
        // under a copy's name. Every device reads the same records and
        // moves the same file, and an edit or a deletion of it is an edit
        // or a deletion of the revision it came from, the way a conflict
        // copy is.
        for _ in 0..<8 {
            var folders: Set<VaultPath> = []
            for path in files.keys {
                for depth in 1..<max(path.components.count, 1) {
                    folders.insert(VaultPath(checked: Array(path.components[0..<depth])))
                }
            }
            let blocking = files.keys.filter { folders.contains($0) }.sorted()
            if blocking.isEmpty { break }
            for path in blocking {
                guard let file = files[path], let note = byRef[file.head] else { continue }
                files[path] = nil
                let moved = Self.conflictCopyPath(of: file.origin, for: note, avoiding: files.keys)
                files[moved] = VaultFile(path: moved, origin: file.origin, text: file.text,
                                         at: file.at, head: file.head)
            }
        }

        self.notes = byRef
        self.files = files
        self.missing = missing
        self.unreadable = unreadable
        self.headsByPath = heads
    }

    public var isEmpty: Bool { files.isEmpty }
    public var isComplete: Bool { missing.isEmpty && unreadable.isEmpty }

    /// The revisions of a path nothing has replaced: one, or more where the
    /// path has been edited in two places at once. A write continues from
    /// all of them.
    public func heads(of path: VaultPath) -> [NoteRef] { headsByPath[path] ?? [] }

    public func isForked(_ path: VaultPath) -> Bool { heads(of: path).count > 1 }

    /// Every path the store holds a revision of, deleted ones included.
    public var knownPaths: [VaultPath] { headsByPath.keys.sorted() }

    /// The text of a file, or nil where the vault holds none.
    public func text(at path: VaultPath) -> String? { files[path]?.text }

    /// Every file, path order.
    public var ordered: [VaultFile] { files.keys.sorted().map { files[$0]! } }

    /// Later wins; the ref breaks a tie, so every device resolves a fork
    /// the same way with no clock to agree on.
    private static func newer(_ a: Note, than b: Note) -> Bool {
        (a.at, a.ref) > (b.at, b.ref)
    }

    /// `Meeting notes (Conflicted copy hub 202609051930).md`, beside the
    /// file it is a copy of: what Obsidian Sync names one, so a vault full
    /// of them reads the way its own do. The stamp is UTC, since every
    /// device derives this name and they agree on no other clock.
    ///
    /// A name already in use is somebody's file, and a copy never takes a
    /// name off a file that is really there, so it keeps looking: the
    /// revision's own sequence number first, since that is stable for as
    /// long as the revision exists, and then a count. Every device reads
    /// the same records in the same order and lands on the same name.
    private static func conflictCopyPath(of origin: VaultPath, for note: Note,
                                         avoiding taken: some Collection<VaultPath>) -> VaultPath {
        let (stem, ext) = origin.stemAndExtension
        let name = "\(stem) (Conflicted copy \(note.ref.device.rawValue) \(stamp(note.at))"
        var candidate = origin.sibling(named: name + ")" + ext)
        guard taken.contains(candidate) else { return candidate }
        candidate = origin.sibling(named: "\(name) \(note.ref.sequence))\(ext)")
        var count = 2
        while taken.contains(candidate) {
            candidate = origin.sibling(named: "\(name) \(note.ref.sequence) \(count))\(ext)")
            count += 1
        }
        return candidate
    }

    private static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d%02d%02d%02d%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// Where the memory is mirrored outside CloudKit, for history and review.
///
/// Recorded only: nothing pushes to it yet. The vault is whole without one
/// — CloudKit holds every revision — and this is the advanced setting that
/// points a vault at a git remote of the person's own.
public struct VaultRemote: Hashable, Sendable {
    public static let recordType = "VaultRemote"
    static let recordID = RecordID("memory/remote")

    public var url: String
    public var branch: String

    public init(url: String, branch: String = "main") {
        self.url = url
        self.branch = branch
    }
}

public enum MemoryError: Error, Sendable {
    /// The vault is missing revisions; writing from it could fork a path
    /// that was never forked. Read again once they are visible.
    case incompleteVault(missing: Set<NoteRef>, unreadable: [RecordID])
    /// Other writers for this device kept taking every sequence number the
    /// writer reached for.
    case sequenceContended(DeviceID)
    /// A marker for this nonce exists but the revision it names cannot be
    /// read. The two are written atomically, so this is a damaged store.
    case markerWithoutNote(nonce: String)
    /// A record was saved and read back as something that is not a revision.
    case damagedNote(RecordID)
    /// A file in the mirror directory is not at a path a vault can hold.
    case notAVaultPath(String)
    /// A setting was being written from more than one place at once and
    /// this writer kept losing. Nothing was applied.
    case settingContended(RecordID)
}
