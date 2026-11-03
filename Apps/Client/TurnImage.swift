import ImageIO
import SwiftUI

/// An image a person's turn carries: the line `ShareInbox.text` writes for a shared or attached
/// image, `[<how>: an image, kept at /home/topo/shared/<nonce>/<name> (<n> bytes)]`, read back
/// out of the turn's words so the bubble can draw the picture where the line was. Only that line,
/// on a line of its own, under the guest's `shared` folder, with a nonce and a name that are each
/// one plain path component, is taken: a turn's words come from the log, which any of the
/// person's devices writes, so nothing else in them is ever read as a path.
struct TurnImage: Equatable {
    /// The image's path in the guest.
    let path: String
    /// The folder under `shared/` and the file's name, each one component.
    let nonce: String
    let name: String
    /// What the turn says before the line and after it, as written but for the blank lines
    /// between them and the line.
    let before: String
    let after: String

    /// The guest's folder shared images are kept under: `ClaudeLauncher.home` and `ShareInbox.folder`.
    static let sharedFolder = "/home/topo/shared/"

    private static let marker = ": an image, kept at "
    /// What `ShareInbox.text` says of where an image came from, and nothing else: a line that
    /// says anything else there is the person's words, drawn as written.
    static let hows: Set<Substring> = ["Shared with Topo from another app", "Attached in Topo from this phone"]

    /// The first image line in `text`, nil when there is none.
    static func find(in text: String) -> TurnImage? {
        var offset = text.startIndex
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let start = offset
            let end = line.endIndex
            offset = end < text.endIndex ? text.index(after: end) : end
            guard let image = read(line) else { continue }
            let before = String(text[..<start])
            let after = end < text.endIndex ? String(text[text.index(after: end)...]) : ""
            // The blank lines that set the line apart go with it: the picture stands apart itself.
            return TurnImage(path: image.path, nonce: image.nonce, name: image.name,
                             before: String(before.reversed().drop { $0 == "\n" }.reversed()),
                             after: String(after.drop { $0 == "\n" }))
        }
        return nil
    }

    /// One line read as the image line, or nil.
    private static func read(_ line: Substring) -> (path: String, nonce: String, name: String)? {
        guard line.hasPrefix("["), line.hasSuffix(" bytes)]"),
              let marker = line.range(of: Self.marker) else { return nil }
        let how = line[line.index(after: line.startIndex)..<marker.lowerBound]
        guard hows.contains(how) else { return nil }
        let rest = line[marker.upperBound..<line.index(line.endIndex, offsetBy: -" bytes)]".count)]
        // The size is the last " (<digits>" of the line; the path is everything before it, so a
        // name with brackets or spaces in it is read whole.
        guard let open = rest.range(of: " (", options: .backwards) else { return nil }
        let digits = rest[open.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        let path = String(rest[..<open.lowerBound])
        guard path.hasPrefix(sharedFolder) else { return nil }
        let parts = path.dropFirst(sharedFolder.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(plain) else { return nil }
        return (path, String(parts[0]), String(parts[1]))
    }

    /// One path component that names something in its folder: not empty, not hidden, no
    /// separator and no control or line-breaking character, judged scalar by scalar.
    private static func plain(_ part: Substring) -> Bool {
        !part.isEmpty && !part.hasPrefix(".")
            && !part.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
                || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }
}

/// The bytes of a turn's image on this device, if it has them: the app hands a reader in through
/// the environment on the chat of the phone Topo lives on (`ShareInbox.imageData`, which opens it
/// beneath the guest's home with no link followed), and a device or a screen without one — a
/// viewer, the watch, the television, the sign-in — draws the line as written. Called off the
/// main actor.
struct TurnImageFiles: Sendable {
    let data: @Sendable (TurnImage) -> Data?
}

private struct TurnImageFilesKey: EnvironmentKey {
    static let defaultValue: TurnImageFiles? = nil
}

extension EnvironmentValues {
    var turnImageFiles: TurnImageFiles? {
        get { self[TurnImageFilesKey.self] }
        set { self[TurnImageFilesKey.self] = newValue }
    }
}

/// Decoded pictures, kept in memory only, at no more than `maxPixels` on their long side, so a
/// transcript of photos holds a few megabytes and not a camera's worth each. The turn on its way
/// and the turn the log has share one decode, so the picture does not blink as the turn lands.
/// `clear` empties it at a sign-out, and a read still under way then keeps nothing: each clear
/// begins an age, and a picture is kept only in the age it was asked for in.
@MainActor
enum TurnImages {
    nonisolated static let maxPixels = 1024
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        return cache
    }()
    private static var age = 0

    final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func cached(_ image: TurnImage) -> CGImage? { cache.object(forKey: image.path as NSString)?.image }

    static func load(_ image: TurnImage, from files: TurnImageFiles) async -> CGImage? {
        if let cached = cached(image) { return cached }
        let asked = age
        let picture = await Task.detached(priority: .userInitiated) { files.data(image).flatMap(decode) }.value
        guard asked == age, let picture else { return nil }
        cache.setObject(Box(picture), forKey: image.path as NSString)
        return picture
    }

    static func clear() {
        age += 1
        cache.removeAllObjects()
    }

    /// The picture in `data`, drawn upright at no more than `maxPixels` on its long side; nil for
    /// anything that is not an image.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The person's words as the bubble draws them: as typed, except that the line an attached or
/// shared image leaves is drawn as the picture, where this device has it. Until the picture is
/// read, and wherever it cannot be, the line is drawn as written, so no word of the turn is ever
/// missing from the screen.
struct PersonWords: View {
    let text: String
    /// Whether the words are drawn with nothing around them, so Topo stands clear of each line.
    var bare = false
    @Environment(\.look) private var look
    @Environment(\.turnImageFiles) private var files
    @State private var loaded: (path: String, image: CGImage)?

    private var image: TurnImage? { files == nil ? nil : TurnImage.find(in: text) }

    var body: some View {
        if let image, let picture = picture(image) {
            VStack(alignment: .trailing, spacing: look.markdown.blockSpacing) {
                if !image.before.isEmpty { words(image.before) }
                Image(decorative: picture, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: look.markdown.imageMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: look.markdown.imageCornerRadius, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("Image \(image.name)")
                    .accessibilityAddTraits(.isImage)
                    .mascotObstacle(bare)
                if !image.after.isEmpty { words(image.after) }
            }
        } else {
            words(text)
                .task(id: image?.path) {
                    guard let image, let files, let picture = await TurnImages.load(image, from: files) else { return }
                    loaded = (image.path, picture)
                }
        }
    }

    /// The picture for `image`: the one this view read, or one an earlier view of the same turn did.
    private func picture(_ image: TurnImage) -> CGImage? {
        if let loaded, loaded.path == image.path { return loaded.image }
        return TurnImages.cached(image)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(look.transcript.bodyFont)
            .foregroundStyle(look.transcript.text)
            .fixedSize(horizontal: false, vertical: true)
            .mascotLines(bare)
    }
}
