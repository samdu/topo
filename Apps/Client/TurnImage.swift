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
        // The how is the line's own words: one line, no bracket of its own.
        let how = line[line.index(after: line.startIndex)..<marker.lowerBound]
        guard !how.isEmpty, !how.contains("["), !how.contains("]") else { return nil }
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

    /// One path component that names something in its folder: not empty, not `.` or `..`,
    /// not hidden, no separator, no control character.
    private static func plain(_ part: Substring) -> Bool {
        !part.isEmpty && !part.hasPrefix(".") && !part.contains("/")
            && !part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

/// Where a turn's image is on this device, if it is: the app hands one in through the environment
/// where it keeps the guest's home (the phone Topo lives on), and a device without it — a viewer,
/// the watch, the television — draws the line as written.
struct TurnImageFiles: Sendable {
    let url: @Sendable (TurnImage) -> URL?
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
/// `clear` empties it at a sign-out.
@MainActor
enum TurnImages {
    nonisolated static let maxPixels = 1024
    private static let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 24
        return cache
    }()

    final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL)?.image }

    static func load(_ url: URL) async -> CGImage? {
        if let image = cached(url) { return image }
        let image = await Task.detached(priority: .userInitiated) { decode(url) }.value
        if let image { cache.setObject(Box(image), forKey: url as NSURL) }
        return image
    }

    static func clear() { cache.removeAllObjects() }

    /// The picture at `url`, drawn upright at no more than `maxPixels` on its long side; nil for
    /// anything that is not a regular file of an image.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
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
    @State private var loaded: (url: URL, image: CGImage)?

    private var image: TurnImage? { files == nil ? nil : TurnImage.find(in: text) }
    private var url: URL? { image.flatMap { files?.url($0) } }

    var body: some View {
        if let image, let url, let picture = picture(url) {
            VStack(alignment: .trailing, spacing: look.transcript.imageSpacing) {
                if !image.before.isEmpty { words(image.before) }
                Image(decorative: picture, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: look.transcript.imageMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: look.transcript.imageCornerRadius, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("Image \(image.name)")
                    .accessibilityAddTraits(.isImage)
                    .mascotObstacle(bare)
                if !image.after.isEmpty { words(image.after) }
            }
        } else {
            words(text)
                .task(id: url) {
                    guard let url, TurnImages.cached(url) == nil, let picture = await TurnImages.load(url) else { return }
                    loaded = (url, picture)
                }
        }
    }

    /// The picture for `url`: the one this view read, or one an earlier view of the same turn did.
    private func picture(_ url: URL) -> CGImage? {
        if let loaded, loaded.url == url { return loaded.image }
        return TurnImages.cached(url)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(look.transcript.bodyFont)
            .foregroundStyle(look.transcript.text)
            .fixedSize(horizontal: false, vertical: true)
            .mascotLines(bare)
    }
}
