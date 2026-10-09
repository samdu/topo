#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// What another app handed the share sheet, read into one thing Topo takes: a file before an
/// image before a link before text, and the first of whichever kind that is. Nothing shared is
/// cut to fit: what is over a limit is refused, as is anything that is not one plain file. The providers are not the system's to hand between
/// threads, so they are read from the main actor, and each answers on a queue of its own.
@MainActor
enum ShareIntake {
    struct Item: Equatable, Sendable {
        var kind: Share.Kind
        /// The text, or the link.
        var text: String?
        /// The image or file, copied into the scratch folder under the name it is kept by.
        var file: URL?
        var bytes: Int?
    }

    /// What one provider holds, as Topo would take it; nil for one it takes nothing from. A file
    /// by its URL is a file whatever is in it, a picture with no file is an image, and data that
    /// is neither a link nor text is a file.
    static func kind(of provider: NSItemProvider) -> Share.Kind? {
        func has(_ type: UTType) -> Bool { provider.hasItemConformingToTypeIdentifier(type.identifier) }
        if has(.fileURL) { return .file }
        if has(.image) { return .image }
        if has(.url) { return .link }
        if has(.text) { return .text }
        if has(.data) { return .file }
        return nil
    }

    /// The provider Topo takes of those shared, and as what.
    static func choice(among providers: [NSItemProvider]) -> (provider: NSItemProvider, kind: Share.Kind)? {
        let order: [Share.Kind] = [.file, .image, .link, .text]
        let kinds = providers.compactMap { provider in kind(of: provider).map { (provider, $0) } }
        for kind in order {
            if let found = kinds.first(where: { $0.1 == kind }) { return found }
        }
        return nil
    }

    /// Reads what was shared. An image or a file is copied into `scratch`, which is the caller's
    /// to take away.
    static func item(from providers: [NSItemProvider], into scratch: URL) async throws(ShareRefusal) -> Item {
        guard let (provider, kind) = choice(among: providers) else { throw .nothing }
        switch kind {
        case .text:
            guard let text = await string(from: provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw .nothing }
            guard text.utf8.count <= Share.textLimit else { throw .tooLong }
            return Item(kind: .text, text: text)
        case .link:
            guard let url = await url(from: provider) else { throw .nothing }
            if url.isFileURL { return try await file(from: provider, as: .file, into: scratch) }
            guard url.absoluteString.utf8.count <= Share.textLimit else { throw .tooLong }
            return Item(kind: .link, text: url.absoluteString)
        case .image, .file:
            return try await file(from: provider, as: kind, into: scratch)
        }
    }

    private static func string(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    /// The type a provider's file is asked for as: its own most particular one, since the copy
    /// the system hands over carries that type's extension.
    static func fileType(of provider: NSItemProvider, as kind: Share.Kind) -> String? {
        let registered = provider.registeredTypeIdentifiers.filter { $0 != UTType.fileURL.identifier && $0 != UTType.url.identifier }
        if kind == .image, let image = registered.first(where: { UTType($0)?.conforms(to: .image) == true }) { return image }
        return registered.first { UTType($0)?.conforms(to: .data) == true } ?? registered.first
    }

    private static func file(from provider: NSItemProvider, as kind: Share.Kind, into scratch: URL) async throws(ShareRefusal) -> Item {
        guard let type = fileType(of: provider, as: kind) else { throw .nothing }
        // The copy the system hands over can be named for its type, so the file's own name is the
        // one the other app suggested, or the one its URL has.
        var suggested = provider.suggestedName
        if suggested?.isEmpty != false, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let original = await url(from: provider), original.isFileURL {
            suggested = original.lastPathComponent
        }
        let result: Result<Item, ShareRefusal> = await withCheckedContinuation { continuation in
            // The file the system hands over is gone when this returns, so it is copied here.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { [suggested] url, _ in
                guard let url, let bytes = ShareStore.size(of: url) else { return continuation.resume(returning: .failure(.nothing)) }
                guard bytes <= Share.fileLimit else { return continuation.resume(returning: .failure(.tooLarge)) }
                var name = Share.name(url.lastPathComponent)
                if let suggested, !suggested.isEmpty {
                    let ending = url.pathExtension
                    let named = (suggested as NSString).pathExtension.isEmpty && !ending.isEmpty ? "\(suggested).\(ending)" : suggested
                    name = Share.name(named)
                }
                let copy = scratch.appendingPathComponent(name)
                guard copy.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL else {
                    return continuation.resume(returning: .failure(.failed))
                }
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: .success(Item(kind: kind, file: copy, bytes: bytes)))
                } catch {
                    continuation.resume(returning: .failure(.failed))
                }
            }
        }
        return try result.get()
    }
}
#endif
