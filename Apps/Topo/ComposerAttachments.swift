import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the composer's `+` offers, and what it does with what the person picks. A pick on this
/// phone goes the way a share from another app does: copied into a scratch folder of the share
/// store's, shown in the share sheet with a field to say something about it, and on Send kept
/// by `ShareStore.keep` under the door's login and drained at once (`ShareInbox`), so one pick
/// is one turn under one nonce, the file goes to the guest's home through `HomeFile`, and the
/// line that marks it says it was attached in Topo. Nothing here writes a turn's text, the
/// photo library or the memory's folder.
///
/// The door is read when an item is pressed, before any picker is put up: signed out, or an
/// image or a file on a phone that is not the guest's, is the sheet's own refusal, so a viewer
/// is told rather than left with a picker whose pick would go nowhere.
@MainActor
@Observable
final class ComposerAttachments {
    /// Where a thing comes from.
    enum Source: String, Identifiable, Sendable {
        /// The phone's file picker, a copy of the one file the person chooses.
        case file
        /// The photo library's picker, one image.
        case photo
        var id: String { rawValue }
    }

    /// The picker on the screen, if one is.
    private(set) var picking: Source?
    /// The share sheet over what was picked, or its refusal, while it is up.
    private(set) var sheet: ShareSheetModel?

    let store: @MainActor () -> ShareStore?
    private let drain: @MainActor () async -> Void

    init(store: @escaping @MainActor () -> ShareStore? = { ShareStore.shared() },
         drain: @escaping @MainActor () async -> Void) {
        self.store = store
        self.drain = drain
    }

    /// What is over the chat for this: a picker, or the sheet. One at a time; the photo picker
    /// and the sheet are one presentation of the chat's, which the sheet follows the picker in,
    /// and the file picker is `fileImporter`'s own.
    enum Up: Identifiable, Equatable {
        case picker(Source)
        case sheet
        var id: String {
            switch self {
            case .picker(let source): source.rawValue
            case .sheet: "sheet"
            }
        }
    }

    var up: Up? {
        if sheet != nil { return .sheet }
        if let picking { return .picker(picking) }
        return nil
    }

    /// The `+`'s item pressed: the door judged first, then the picker up. A second press while
    /// one is up does nothing.
    func pick(_ source: Source) {
        guard picking == nil, sheet == nil else { return }
        guard let store = store(), let door = store.door() else { return refuse(.signedOut) }
        guard door.files else { return refuse(.anotherPhone) }
        picking = source
    }

    /// The picker came down with nothing: cancelled, or swiped away.
    func dismissed(_ source: Source) {
        guard picking == source else { return }
        picking = nil
    }

    /// The file picker's choice: the picker goes down and the sheet goes up at once, reading,
    /// while the file is copied into a scratch folder of the store's off the main actor; the
    /// copy lands on the sheet it was made for, which takes it or, cancelled meanwhile, takes
    /// it away. The system hands over the original under its grant, not a copy, so the copy
    /// is this one's and its reading can take as long as an iCloud download.
    func chose(file url: URL) {
        guard picking == .file, let store = store() else { return dismissed(.file) }
        picking = nil
        let model = ShareSheetModel(store: store, via: .composer)
        sheet = model
        Task.detached(priority: .userInitiated) {
            let outcome = ComposerAttachments.copy(url, as: .file, into: store)
            await MainActor.run { model.took(outcome) }
        }
    }

    /// The photo picker's choice, or nothing: the picker goes down and the sheet goes up,
    /// reading the provider as the extension reads one (`ShareSheetModel.read`), so a HEIC
    /// transcoded to a JPEG, or a photo brought down from iCloud, is read behind the sheet.
    func chose(photo provider: NSItemProvider?) {
        guard picking == .photo else { return }
        picking = nil
        guard let provider else { return }
        let model = ShareSheetModel(store: store(), via: .composer)
        sheet = model
        Task { await model.read([provider]) }
    }

    /// The sheet's Cancel: the thing goes with it, and a read or a copy still landing keeps nothing.
    func cancel() {
        sheet?.discard()
        sheet = nil
    }

    /// The sheet's Send: kept as a share and drained now. A keep the store refused leaves the
    /// sheet up saying why.
    func send() {
        guard let sheet, sheet.keep() else { return }
        self.sheet = nil
        Task { await drain() }
    }

    private func refuse(_ refusal: ShareRefusal) {
        let model = ShareSheetModel(store: store(), via: .composer)
        model.refuse(refusal)
        sheet = model
    }

    /// What a copy hands back.
    enum Picked {
        case taken(ShareIntake.Item, scratch: URL)
        case refused(ShareRefusal, scratch: URL?)
    }

    /// A copy of the file at `url` in a fresh scratch folder of the store's, under the name the
    /// store keeps it by, judged against the store's limit; the copy is what the picker's caller
    /// hands the sheet. `url` is read under its own grant where it has one (a file picker's URL).
    nonisolated static func copy(_ url: URL, as kind: Share.Kind, into store: ShareStore) -> Picked {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = ShareStore.size(of: url) else { return .refused(.nothing, scratch: nil) }
        guard bytes <= Share.fileLimit else { return .refused(.tooLarge, scratch: nil) }
        // No scratch is made with the door shut: a sign-out took the folder, and nothing kept
        // in it could be sent.
        guard store.door() != nil else { return .refused(.signedOut, scratch: nil) }
        guard let scratch = try? store.scratch() else { return .refused(.failed, scratch: nil) }
        let copy = scratch.appendingPathComponent(Share.name(url.lastPathComponent))
        guard copy.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL else {
            return .refused(.failed, scratch: scratch)
        }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            return .refused(.failed, scratch: scratch)
        }
        return .taken(ShareIntake.Item(kind: kind, file: copy, bytes: bytes), scratch: scratch)
    }
}

/// The pickers and the sheet, hung on the chat: each is up while the model says so, and hands
/// back what it holds. The file picker is SwiftUI's own (`fileImporter`, one file of any kind,
/// opened under its grant and copied by `ComposerAttachments.copy`), the photo picker the
/// system's over the library in its compatible representation, so a HEIC arrives as a JPEG the
/// mind can read; one image, chosen with no permission asked. The photo picker and the sheet
/// are one presentation (`Up`), so the sheet follows the picker as SwiftUI sequences the two,
/// and neither is swiped away: the picker's Cancel and the sheet's are the ways down, so every
/// change of what is up is the model's own.
struct ComposerPickers: ViewModifier {
    @Bindable var attachments: ComposerAttachments
    var marks: ShareSheet.Marks

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: fileUp, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return attachments.dismissed(.file) }
                attachments.chose(file: url)
            }
            .sheet(item: up) { up in
                switch up {
                case .picker(.photo):
                    PhotoPicker { provider in attachments.chose(photo: provider) }
                        .ignoresSafeArea()
                        .interactiveDismissDisabled()
                case .picker(.file):
                    // The file picker is `fileImporter`'s, not a sheet of this one's.
                    EmptyView()
                case .sheet:
                    if let model = attachments.sheet {
                        ShareSheet(model: model, waits: false, marks: marks, cancel: attachments.cancel, send: attachments.send)
                            .interactiveDismissDisabled()
                    }
                }
            }
    }

    private var fileUp: Binding<Bool> {
        Binding(get: { attachments.picking == .file },
                set: { up in if !up { attachments.dismissed(.file) } })
    }

    /// What is presented: the photo picker or the sheet. Nothing is written back: a nil the
    /// system writes as one presentation gives way to the next is not a cancel, and neither
    /// can be swiped away.
    private var up: Binding<ComposerAttachments.Up?> {
        Binding(get: { attachments.picking == .file ? nil : attachments.up }, set: { _ in })
    }
}

extension ShareSheetModel {
    /// What a copy made for this sheet hands back.
    func took(_ outcome: ComposerAttachments.Picked) {
        switch outcome {
        case .taken(let item, let scratch): take(item, in: scratch)
        case .refused(let refusal, let scratch):
            if let scratch { discardScratch(scratch) }
            refuse(refusal)
        }
    }
}

/// `PHPickerViewController` over the library, one image, in the compatible representation.
struct PhotoPicker: UIViewControllerRepresentable {
    let chosen: @MainActor (NSItemProvider?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(chosen: chosen) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let chosen: @MainActor (NSItemProvider?) -> Void
        private var answered = false

        init(chosen: @escaping @MainActor (NSItemProvider?) -> Void) {
            self.chosen = chosen
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // One answer a picker, whatever the system does after.
            guard !answered else { return }
            answered = true
            let provider = results.first?.itemProvider
            MainActor.assumeIsolated { chosen(provider) }
        }
    }
}
