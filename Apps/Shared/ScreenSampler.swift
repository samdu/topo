#if os(iOS)
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Which of a broadcast's frames become stills: at most one every `interval`, and only one that
/// differs from the last kept, so a screen that is not changing costs nothing and one that is
/// costs a still every second or two. Video is never kept: a frame is judged, encoded as a JPEG
/// or dropped.
///
/// A frame is judged by each of its channels averaged over a grid of cells, which a typed
/// character or a moved cursor changes and the sensor noise of nothing does, since a screen has
/// none. Every channel is read, so a change of colour alone is a change.
///
/// A frame taken is not yet a still: `kept` is told once it is on disk, so a frame whose write
/// was dropped is taken again the next time it is offered.
struct ScreenSampler {
    /// The least time between two stills.
    static let interval: TimeInterval = 1.5
    /// A still's long side, in pixels.
    static let longSide: CGFloat = 1568
    static let quality: CGFloat = 0.6
    /// The grid a frame's channels are averaged over, cells a side.
    static let grid = 24
    /// How far one cell's average has to move, of 255, for the frame to count as changed.
    static let moved = 0.25

    private var last: Date?
    private var mark: [Double]?
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// A frame to keep: its JPEG, and what `kept` is handed once it is kept.
    struct Taken {
        var jpeg: Data
        fileprivate var mark: [Double]?
    }

    /// Whether a frame offered at `now` is inside the interval since the last still, and so not
    /// judged at all.
    func early(at now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) < Self.interval } ?? false
    }

    /// The frame as a JPEG if it is one to keep, turned the way the screen was held.
    func take(_ frame: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, at now: Date) -> Taken? {
        if early(at: now) { return nil }
        let seen = Self.mark(of: frame)
        // A frame in a format this cannot judge is kept on the interval alone.
        if let seen, let mark, !Self.changed(from: mark, to: seen) { return nil }
        var image = CIImage(cvPixelBuffer: frame).oriented(orientation)
        let scale = Self.longSide / max(image.extent.width, image.extent.height)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: space, options: [
                  CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.quality
              ]) else { return nil }
        return Taken(jpeg: jpeg, mark: seen)
    }

    /// That frame is a still now: the next is judged against it, and no sooner than `interval`.
    mutating func kept(_ taken: Taken, at now: Date) {
        last = now
        mark = taken.mark
    }

    static func changed(from old: [Double], to new: [Double]) -> Bool {
        guard old.count == new.count else { return true }
        return zip(old, new).contains { abs($0 - $1) >= moved }
    }

    /// Each channel of the frame averaged over each cell of the grid, of 255, one channel after
    /// another: luma, Cb and Cr of a planar frame, blue, green and red of a BGRA one. Nil for any
    /// other format.
    static func mark(of frame: CVPixelBuffer) -> [Double]? {
        guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        switch CVPixelBufferGetPixelFormatType(frame) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(frame) == 2,
                  let luma = averages(CVPixelBufferGetBaseAddressOfPlane(frame, 0), width: CVPixelBufferGetWidthOfPlane(frame, 0),
                                      height: CVPixelBufferGetHeightOfPlane(frame, 0), row: CVPixelBufferGetBytesPerRowOfPlane(frame, 0),
                                      channels: 1, skipping: 2),
                  // The chroma plane is already half the frame each way, so all of it is read.
                  let chroma = averages(CVPixelBufferGetBaseAddressOfPlane(frame, 1), width: CVPixelBufferGetWidthOfPlane(frame, 1),
                                        height: CVPixelBufferGetHeightOfPlane(frame, 1), row: CVPixelBufferGetBytesPerRowOfPlane(frame, 1),
                                        channels: 2, skipping: 1) else { return nil }
            return luma + chroma
        case kCVPixelFormatType_32BGRA:
            return averages(CVPixelBufferGetBaseAddress(frame), width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame),
                            row: CVPixelBufferGetBytesPerRow(frame), channels: 3, of: 4, skipping: 2)
        default:
            return nil
        }
    }

    /// The first `channels` bytes of each pixel of a plane, `of` bytes a pixel, each averaged over
    /// each cell of the grid. Every `skipping`th pixel of every `skipping`th row is read: at two, a
    /// quarter of the frame, which a character still moves.
    private static func averages(_ base: UnsafeMutableRawPointer?, width: Int, height: Int, row: Int, channels: Int, of size: Int? = nil,
                                 skipping: Int) -> [Double]? {
        let size = size ?? channels, cells = grid * grid
        guard let base, width * 2 / skipping >= grid, height * 2 / skipping >= grid else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sums = [Int](repeating: 0, count: cells * channels)
        var counts = [Int](repeating: 0, count: cells)
        for y in stride(from: 0, to: height, by: skipping) {
            let cellRow = y * grid / height * grid
            let line = bytes + y * row
            for x in stride(from: 0, to: width, by: skipping) {
                let cell = cellRow + x * grid / width
                for channel in 0..<channels { sums[channel * cells + cell] += Int(line[x * size + channel]) }
                counts[cell] += 1
            }
        }
        return sums.indices.map { counts[$0 % cells] == 0 ? 0 : Double(sums[$0]) / Double(counts[$0 % cells]) }
    }
}
#endif
