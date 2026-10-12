import Foundation
import TopoTools
import TopoUserland
import UIKit
import UniformTypeIdentifiers

/// What the phone's file picker came back with.
enum FilePick: Sendable, Equatable {
    /// A copy of the file the person chose, which the picker's caller removes.
    case picked(URL)
    case cancelled
    /// Nobody chose within the picker's bound.
    case unanswered
    /// The picker could not be put up, and why.
    case unavailable(String)
}

/// The phone's own file picker, put up over the app for the person to choose one file.
protocol FilePicker: Sendable {
    func pick() async -> FilePick
}

/// Where a picked file is put: the memory's folder as the guest reaches it.
protocol VaultDrop: Sendable {
    /// Puts `data` at `folder`/`name` in the memory, where nothing is yet, and gives it its name
    /// no later than one wait of the vault's after `deadline`.
    func drop(_ data: Data, named name: String, into folder: String, by deadline: Date) async throws -> VaultDropOutcome
}

enum VaultDropOutcome: Sendable, Equatable {
    case placed
    /// Something is at that name already; nothing was written.
    case exists
    /// The memory's folder is not mounted in the guest.
    case unmounted
    /// The copy was not done by the deadline; nothing was given the name.
    case late
}

/// `topo files pick`: the person chooses a file from Files, iCloud Drive or another app's
/// documents, and a copy of it lands in the memory, where the mind reads it.
struct FilesTool: Tool {
    let picker: any FilePicker
    let drop: any VaultDrop

    /// The folder in the memory a pick lands in unless `--into` names another.
    static let inbox = "inbox"
    /// The most bytes a picked file may be.
    static let bytes = 20 * 1024 * 1024
    /// The most bytes a picked file that is text may be, which is this tool's own line: the mirror
    /// carries a text file to the store whole, as one note, in one field of one record.
    static let textBytes = 256 * 1024
    /// The most bytes a picked file's name may be.
    static let nameBytes = 200
    /// How long after the call began a pick may still be given its name in the memory: that and
    /// one wait of the vault's (`Guest.vaultWait`) end inside the tool service's bound, so a call
    /// answered as timed out puts nothing there afterwards.
    static let placeBy: TimeInterval = 65

    let name = "files"
    let summary = "ask the person to pick a file on the phone, and put a copy of it in the memory"
    var usage: String { """
    topo files pick [--into FOLDER]     put up the phone's file picker; the file the person picks is copied to
                                        \(ClaudeLauncher.memory)/FOLDER (\(Self.inbox) unless --into names another), under its own name,
                                        and its path printed. The person has a minute to choose. At most \(Self.bytes / 1024 / 1024) MB, and
                                        \(Self.textBytes / 1024) KB for a text file. Nothing already there is written over
    """ }

    func run(_ arguments: [String]) async -> ToolReply {
        let deadline = Date().addingTimeInterval(Self.placeBy)
        let folder: String
        do {
            folder = try parse(arguments)
        } catch let refusal as Arguments.Refusal {
            return .usage("topo: \(refusal)\n\n\(usage)\n")
        } catch {
            return .usage("topo: \((error as? Misuse)?.text ?? "files takes pick")\n\n\(usage)\n")
        }
        let url: URL
        switch await picker.pick() {
        case .picked(let picked): url = picked
        case .cancelled: return .failed("topo: the person closed the picker without choosing a file\n")
        case .unanswered: return .failed("topo: nobody chose a file within a minute, so the picker was taken down; run it again when the person is ready\n")
        case .unavailable(let why): return .failed("topo: \(why)\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        // Cancelled is the service's bound passed while the picker was up: the caller has been told
        // the call timed out, so nothing is put in the memory now.
        guard !Task.isCancelled else { return PhoneTool.late }
        let name = Self.fileName(url.lastPathComponent)
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.bytes else {
                return refused("\(name) is \(size / 1024 / 1024) MB, over the \(Self.bytes / 1024 / 1024) MB a picked file may be")
            }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failed("topo: the picked file could not be read: \(error.localizedDescription)\n")
        }
        guard data.count <= Self.bytes else {
            return refused("\(name) is over the \(Self.bytes / 1024 / 1024) MB a picked file may be")
        }
        let isText = String(data: data, encoding: .utf8) != nil
        guard !isText || data.count <= Self.textBytes else {
            return refused("\(name) is \(data.count / 1024) KB of text, over the \(Self.textBytes / 1024) KB a note in the memory may be")
        }
        let path = "\(ClaudeLauncher.memory)/\(folder)/\(name)"
        do {
            switch try await drop.drop(data, named: name, into: folder, by: deadline) {
            case .placed:
                let kept = isText ? "" : "It is not text, so the memory's sync does not carry it to the person's other devices: it is in this memory folder alone.\n"
                return .ok("picked: \(path) (\(data.count) bytes)\n\(kept)")
            case .exists:
                return refused("\(path) is already there, so nothing was written; pass --into another folder, or move that file first")
            case .unmounted:
                return .failed("topo: the memory's folder is not reachable from here, so there is nowhere to put the file; nothing was kept\n")
            case .late:
                return .failed("topo: the file was picked too late in the call to be copied into the memory, so nothing was kept; run it again\n")
            }
        } catch let failure as ToolFailure {
            return ToolReply(status: failure.status, text: "topo: \(failure.text)\n")
        } catch {
            return .failed("topo: \(error.localizedDescription)\n")
        }
    }

    private func refused(_ why: String) -> ToolReply {
        ToolReply(status: ToolReply.refused, text: "topo: \(why)\n")
    }

    /// The folder a call names, or why it is not a call.
    func parse(_ arguments: [String]) throws -> String {
        let parsed = try Arguments(arguments, options: ["into"])
        guard parsed.words == ["pick"] else { throw Misuse("files takes pick") }
        guard let into = parsed.options["into"] else { return Self.inbox }
        guard let folder = Self.folder(into) else {
            throw Misuse("--into is a folder in the memory, written from its root: notes/papers. No . or .., and no name starting with a dot")
        }
        return folder
    }

    /// `text` as a folder in the memory, or nil: relative, each name a plain one. A name starting
    /// with a dot is refused, since the mirror reads no hidden name and `.topo` is its own.
    static func folder(_ text: String) -> String? {
        let names = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !text.hasPrefix("/"), !names.isEmpty, names.count <= 8,
              names.allSatisfy({ !$0.hasPrefix(".") && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: Self.unprintable) }) else {
            return nil
        }
        return names.joined(separator: "/")
    }

    /// The name a picked file is kept under: its own, with whatever would make it a path, a hidden
    /// name or more than one line taken out.
    static func fileName(_ picked: String) -> String {
        var name = String(String.UnicodeScalarView(picked.unicodeScalars.filter { !unprintable($0) && $0 != "/" }))
        name = String(name.drop { $0 == "." || $0 == " " })
        if name.utf8.count > nameBytes {
            let ending = (name as NSString).pathExtension
            let kept = ending.isEmpty || ending.utf8.count > 16 ? "" : "." + ending
            var stem = String(name.dropLast(kept.count))
            while stem.utf8.count + kept.utf8.count > nameBytes { stem.removeLast() }
            name = stem + kept
        }
        return name.isEmpty ? "file" : name
    }

    private static func unprintable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7f || scalar.properties.generalCategory == .lineSeparator
            || scalar.properties.generalCategory == .paragraphSeparator
    }
}

/// `UIDocumentPickerViewController`, asked for a copy: the picker hands the app its own copy of the
/// file, so nothing of the person's is opened in place and no grant is kept. One picker at a time,
/// only while the app is on the screen, and taken down at its bound or its call's cancellation.
@MainActor
final class DocumentPicker: NSObject, FilePicker, UIDocumentPickerDelegate {
    /// How long the person has to choose: under the tool service's own bound, with room left for
    /// the copy into the memory.
    nonisolated static let bound: Duration = .seconds(60)

    /// The call a picker is up for, and the picker, held here until that call is answered: the
    /// bound and the cancellation name the call, so neither answers a later one, and neither
    /// depends on the picker still being on the screen.
    private var waiting: (call: UUID, continuation: CheckedContinuation<FilePick, Never>)?
    private var shown: UIDocumentPickerViewController?

    nonisolated func pick() async -> FilePick {
        let call = UUID()
        return await withTaskCancellationHandler {
            await present(call)
        } onCancel: {
            Task { @MainActor in self.finish(.cancelled, call: call) }
        }
    }

    private func present(_ call: UUID) async -> FilePick {
        guard waiting == nil else { return .unavailable("a file picker is already up on the phone") }
        guard !Task.isCancelled else { return .cancelled }
        guard UIApplication.shared.applicationState == .active, let presenter = Self.presenter() else {
            return .unavailable("the Topo app is not on the screen, or is between two screens, so no picker can be shown; ask the person to open Topo, then run it again")
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        shown = picker
        return await withCheckedContinuation { continuation in
            waiting = (call, continuation)
            presenter.present(picker, animated: true)
            Task {
                try? await Task.sleep(for: Self.bound)
                self.finish(.unanswered, call: call)
            }
        }
    }

    /// The view controller on top of the app's key window, which is what can present; nil while
    /// the one on top is on its way off the screen, when nothing can.
    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else {
            return nil
        }
        while let next = top.presentedViewController { top = next }
        return top.isBeingDismissed ? nil : top
    }

    private func finish(_ pick: FilePick, call: UUID) {
        guard let waiting, waiting.call == call else { return }
        self.waiting = nil
        if let shown, shown.presentingViewController != nil { shown.dismiss(animated: true) }
        shown = nil
        waiting.continuation.resume(returning: pick)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // A choice that lands after its call was answered is of no use to anyone: its copy goes.
        guard controller === shown, let call = waiting?.call, let url = urls.first else {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            if controller === shown, let call = waiting?.call { finish(.cancelled, call: call) }
            return
        }
        finish(.picked(url), call: call)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === shown, let call = waiting?.call else { return }
        finish(.cancelled, call: call)
    }
}

/// A picked file carried into the memory by the guest itself: the app writes it into the guest's
/// home, and the guest copies it from there into the memory's folder (`VaultPlacement`). So the
/// folder has no writer but the vault's own filesystem, with its coordination, its bound and its
/// refusal of `.topo`, and a pick lands in the folder the guest's mount is on.
struct GuestVaultDrop: VaultDrop {
    /// Whether the memory's folder is mounted in the guest now.
    var mounted: @Sendable () async -> Bool = { await MainActor.run { GuestResident.shared.vault.standing?.identity != nil } }
    var home: @Sendable () -> URL = { GuestResident.homeDirectory }

    /// Where a pick waits in the home for the guest to copy it: the app's own folder there.
    static let staging = [".topo", "picked"]
    /// A pick left waiting by a call the app was killed under is taken away once it is this old.
    static let stale: TimeInterval = 10 * 60

    func drop(_ data: Data, named name: String, into folder: String, by deadline: Date) async throws -> VaultDropOutcome {
        guard Guest.shared.kernels > 0, await mounted() else { return .unmounted }
        HomeFile.clear(Self.staging, under: home(), olderThan: Self.stale)
        let staged = UUID().uuidString
        guard try HomeFile.create(data, named: staged, in: Self.staging, under: home()) == .created else {
            throw ToolFailure("the picked file could not be handed to the guest")
        }
        defer { HomeFile.remove(named: staged, in: Self.staging, under: home()) }
        try Task.checkCancellation()
        let source = ([ClaudeLauncher.home] + Self.staging + [staged]).joined(separator: "/")
        switch try await VaultPlacement.place(source, folder: folder, name: name, by: deadline) {
        case .placed(let bytes):
            guard bytes == data.count else { throw ToolFailure("the file's copy into the memory could not be confirmed") }
            return .placed
        case .exists: return .exists
        case .unmounted: return .unmounted
        case .late: return .late
        case .noFolder: throw ToolFailure("the folder \(folder) could not be made in the memory")
        case .failed: throw ToolFailure("the file could not be copied into the memory (the copy has \(VaultPlacement.copySeconds) s)")
        }
    }
}
