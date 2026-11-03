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
        /// The camera, one capture.
        case camera
        var id: String { rawValue }
    }

    /// The picker on the screen, if one is.
    private(set) var picking: Source?
    /// The share sheet over what was picked, or its refusal, while it is up.
    private(set) var sheet: ShareSheetModel?

    /// Whether this phone has a camera to offer, asked as the menu is built and again at the
    /// press: none on a simulator, so the item is not there, and one a restriction has taken
    /// since the menu was built puts nothing up, since a picker over a source the phone lacks is
    /// an exception rather than a refusal.
    let cameraAvailable: @MainActor () -> Bool
    var hasCamera: Bool { cameraAvailable() }
    /// The file picker, held here rather than by a view: the chat's views come and go while the
    /// picker is up, and a picker whose holder went with them never hands back its pick.
    @ObservationIgnored let files = AttachmentFilePicker()

    let store: @MainActor () -> ShareStore?
    private let drain: @MainActor () async -> Void

    init(store: @escaping @MainActor () -> ShareStore? = { ShareStore.shared() },
         drain: @escaping @MainActor () async -> Void,
         cameraAvailable: @escaping @MainActor () -> Bool = { UIImagePickerController.isSourceTypeAvailable(.camera) }) {
        self.store = store
        self.drain = drain
        self.cameraAvailable = cameraAvailable
    }

    /// What is over the chat for this: a picker, or the sheet. One at a time; the photo picker
    /// and the sheet are one presentation of the chat's, which the sheet follows the picker in,
    /// the file picker is presented by UIKit (`AttachmentFilePicker`) and the camera is a cover of
    /// its own, so a `.picker` of either of those is up as something other than the sheet's
    /// presentation.
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
    /// one is up does nothing, and nor does the camera where there is none; a file picker the
    /// model still counts up that has been off the screen for a while without answering is let
    /// go first, so the `+` is never dead.
    func pick(_ source: Source) {
        if picking == .file, sheet == nil, files.abandoned() {
            picking = nil
        }
        guard picking == nil, sheet == nil, source != .camera || hasCamera else { return }
        guard let store = store(), let door = store.door() else { return refuse(.signedOut) }
        guard door.files else { return refuse(.anotherPhone) }
        picking = source
    }

    /// The photo picker came down with nothing (`chose(photo: nil)` is its way), or a suite says
    /// a picker went.
    func dismissed(_ source: Source) {
        guard picking == source else { return }
        picking = nil
    }

    /// The file picker's choice, or nothing: the picker goes down and the sheet goes up at once,
    /// reading, while the file is copied into a scratch folder of the store's off the main actor;
    /// the copy lands on the sheet it was made for, which takes it or, cancelled meanwhile, takes
    /// it away. The picker hands over a copy of its own in the app's temporary folder, already
    /// downloaded, which is taken away once it is copied, whatever came of the copy.
    func chose(file url: URL?) {
        guard picking == .file else {
            if let url { ComposerAttachments.removePickerCopy(url) }
            return
        }
        picking = nil
        guard let url else { return }
        guard let store = store() else {
            ComposerAttachments.removePickerCopy(url)
            return refuse(.signedOut)
        }
        let model = ShareSheetModel(store: store, via: .composer)
        sheet = model
        Task.detached(priority: .userInitiated) {
            let outcome = ComposerAttachments.copy(url, as: .file, into: store)
            ComposerAttachments.removePickerCopy(url)
            await MainActor.run { model.took(outcome) }
        }
    }

    /// Takes away the copy the file picker made, which it puts in an `-Inbox` folder of the app's
    /// temporary folder, and nothing else: a URL anywhere but there is left where it is.
    nonisolated static func removePickerCopy(_ url: URL) {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let copy = url.resolvingSymlinksInPath().standardizedFileURL
        let inbox = copy.deletingLastPathComponent()
        guard inbox.lastPathComponent.hasSuffix("-Inbox"),
              inbox.deletingLastPathComponent().path == temporary.path else { return }
        try? FileManager.default.removeItem(at: copy)
    }

    /// The file picker put up by UIKit, once `picking` says it is up; one that cannot be put up
    /// (the app between two screens) is the sheet's refusal, not a silent nothing.
    func presentFilePicker() {
        guard picking == .file else { return }
        guard files.present({ [weak self] url in self?.chose(file: url) }) else {
            picking = nil
            return refuse(.noPicker)
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

    /// The camera's capture, or nothing: the cover goes down and the sheet goes up, reading,
    /// while the capture is drawn and written off the main actor (`capture`).
    func chose(camera image: UIImage?) {
        guard picking == .camera else { return }
        picking = nil
        guard let image, let store = store() else { return }
        let model = ShareSheetModel(store: store, via: .composer)
        sheet = model
        let time = Date()
        Task.detached(priority: .userInitiated) {
            let outcome = ComposerAttachments.capture(image, at: time, into: store)
            await MainActor.run { model.took(outcome) }
        }
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

    /// The longest side a capture is kept at, the line `topo photos export` draws.
    nonisolated static let captureSide: CGFloat = 2048
    /// The quality a capture's JPEG is written at.
    nonisolated static let captureQuality: CGFloat = 0.9

    /// What the camera took, as a JPEG in a fresh scratch folder of the store's: drawn upright at
    /// no more than `captureSide` on its long side, so the file is the picture as the person saw
    /// it whichever way the phone was held and small enough to read, and named for the moment.
    /// It is written nowhere else: not the photo library, which `topo photos save` alone adds to.
    nonisolated static func capture(_ image: UIImage, at time: Date, into store: ShareStore) -> Picked {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > captureSide ? captureSide / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(.down), height: (image.size.height * scale).rounded(.down))
        guard size.width >= 1, size.height >= 1 else { return .refused(.nothing, scratch: nil) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = upright.jpegData(compressionQuality: captureQuality) else { return .refused(.failed, scratch: nil) }
        guard data.count <= Share.fileLimit else { return .refused(.tooLarge, scratch: nil) }
        guard store.door() != nil else { return .refused(.signedOut, scratch: nil) }
        guard let scratch = try? store.scratch() else { return .refused(.failed, scratch: nil) }
        let copy = scratch.appendingPathComponent(Share.name(captureName(at: time)))
        do {
            try data.write(to: copy, options: .withoutOverwriting)
        } catch {
            return .refused(.failed, scratch: scratch)
        }
        return .taken(ShareIntake.Item(kind: .image, file: copy, bytes: data.count), scratch: scratch)
    }

    /// `Photo 2026-11-01 21-55-03.jpg`, in the phone's own time zone: no colon, which the
    /// store's name rules drop.
    nonisolated static func captureName(at time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Photo \(formatter.string(from: time)).jpg"
    }

    /// A copy of the file at `url` in a fresh scratch folder of the store's, under the name the
    /// store keeps it by, judged against the store's limit; the copy is what the picker's caller
    /// hands the sheet. `url` is read under its own grant where it has one; the file picker's is
    /// a copy of its own and has none.
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
/// back what it holds. The photo picker is the system's over the library in its compatible
/// representation, so a HEIC arrives as a JPEG the mind can read; one image, chosen with no
/// permission asked. It and the sheet are one presentation (`Up`), so the sheet follows the
/// picker as SwiftUI sequences the two. The camera is the system's over the whole screen
/// (`CameraPicker`, a cover of its own, which hands back what it took or nothing). The file
/// picker is the system's document picker, put up by UIKit over whatever is on top
/// (`AttachmentFilePicker`) and answering through its delegate
/// alone: SwiftUI's own (`fileImporter`) writes its `isPresented` false before it hands over the
/// pick, and a binding that took that write as a cancel dropped every pick. What it picked
/// reaches the model only once it is off the screen, so the sheet that follows is not put up
/// over a picker still going. The photo picker and the sheet are not swiped away, and
/// a swipe on the file picker is its Cancel: every change of what is up is the model's own.
struct ComposerPickers: ViewModifier {
    @Bindable var attachments: ComposerAttachments
    var marks: ShareSheet.Marks

    func body(content: Content) -> some View {
        content
            .onChange(of: attachments.picking == .file) { _, up in
                guard up else { return }
                attachments.presentFilePicker()
            }
            .sheet(item: up) { up in
                switch up {
                case .picker(.photo):
                    PhotoPicker { provider in attachments.chose(photo: provider) }
                        .ignoresSafeArea()
                        .interactiveDismissDisabled()
                case .picker(.file), .picker(.camera):
                    // The file picker is UIKit's and the camera the cover's, not a sheet of
                    // this one's.
                    EmptyView()
                case .sheet:
                    if let model = attachments.sheet {
                        ShareSheet(model: model, waits: false, marks: marks, cancel: attachments.cancel, send: attachments.send)
                            .interactiveDismissDisabled()
                    }
                }
            }
            // The camera takes the whole screen, as the system's does.
            .fullScreenCover(isPresented: cameraUp) {
                CameraPicker { image in attachments.chose(camera: image) }
                    .ignoresSafeArea()
            }
    }

    private var cameraUp: Binding<Bool> {
        Binding(get: { attachments.picking == .camera },
                set: { up in if !up { attachments.dismissed(.camera) } })
    }

    /// What is presented: the photo picker or the sheet. Nothing is written back: a nil the
    /// system writes as one presentation gives way to the next is not a cancel, and neither
    /// can be swiped away.
    private var up: Binding<ComposerAttachments.Up?> {
        Binding(get: { attachments.picking == .file || attachments.picking == .camera ? nil : attachments.up }, set: { _ in })
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

/// `UIDocumentPickerViewController` over every kind of file, one file, handed over as a copy in
/// the app's temporary folder, put up by UIKit over the view controller on top. Its answer, the
/// copy, or nil for its Cancel (a swipe down included), is handed over once the picker has left
/// the screen, and once only.
@MainActor
final class AttachmentFilePicker: NSObject, UIDocumentPickerDelegate {
    private var shown: UIDocumentPickerViewController?
    private var chosen: (@MainActor (URL?) -> Void)?
    private var presented: Date?

    /// How long a picker may be off the screen without answering before it is taken for gone:
    /// longer than a presentation takes to land.
    static let grace: TimeInterval = 3

    /// A picker put up more than `grace` ago that is not on the screen and never answered: let
    /// go, so the next press puts up another. False while one is up or none is held.
    func abandoned(now: Date = Date()) -> Bool {
        guard let shown, let presented, now.timeIntervalSince(presented) > Self.grace,
              shown.presentingViewController == nil, !shown.isBeingPresented else { return false }
        self.shown = nil
        self.chosen = nil
        self.presented = nil
        return true
    }

    /// Puts the picker up; false when one is already up or nothing can present it.
    func present(_ chosen: @escaping @MainActor (URL?) -> Void) -> Bool {
        guard shown == nil, let presenter = Self.presenter() else { return false }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        shown = picker
        self.chosen = chosen
        presented = Date()
        presenter.present(picker, animated: true)
        return true
    }

    /// The view controller on top of the app's key window, which is what can present; nil while
    /// the one on top is on its way off the screen.
    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else {
            return nil
        }
        while let next = top.presentedViewController { top = next }
        return top.isBeingDismissed ? nil : top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        urls.dropFirst().forEach { ComposerAttachments.removePickerCopy($0) }
        answer(controller, urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        answer(controller, nil)
    }

    /// The answer, handed over when the picker is off the screen: after its own dismissal where
    /// it is still up or on its way down, at once where it has already gone.
    private func answer(_ controller: UIDocumentPickerViewController, _ url: URL?) {
        guard controller === shown, let chosen else {
            if let url { ComposerAttachments.removePickerCopy(url) }
            return
        }
        shown = nil
        self.chosen = nil
        presented = nil
        let hand = { MainActor.assumeIsolated { chosen(url) } }
        if controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true, completion: hand)
        } else if let transition = controller.transitionCoordinator {
            // Called whether the transition finished or was cancelled: either way it is over.
            transition.animate(alongsideTransition: nil) { _ in hand() }
        } else {
            hand()
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

/// `UIImagePickerController` on the camera: one capture, handed back as the image it took, and
/// nothing saved anywhere by the picker.
struct CameraPicker: UIViewControllerRepresentable {
    let took: @MainActor (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(took: took) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let took: @MainActor (UIImage?) -> Void
        private var answered = false

        init(took: @escaping @MainActor (UIImage?) -> Void) {
            self.took = took
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !answered else { return }
            answered = true
            let image = info[.originalImage] as? UIImage
            MainActor.assumeIsolated { took(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !answered else { return }
            answered = true
            MainActor.assumeIsolated { took(nil) }
        }
    }
}
