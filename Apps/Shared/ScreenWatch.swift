#if os(iOS)
import CoreVideo
import Foundation
import ImageIO

/// One broadcast's frames and ticks, made into stills: what the extension does with what
/// ReplayKit hands it, apart from ReplayKit, so a suite can hand it the same.
///
/// A frame arriving inside the interval since the last still is held, one at a time, and judged
/// at the first tick past the interval: ReplayKit sends none while the screen rests, so the last
/// frame held is the screen as it came to rest. A tick also marks the broadcast as running and
/// reads the door again. Either answers a refusal where the broadcast is to end.
struct ScreenWatch {
    let store: ScreenStore
    let door: ScreenStore.Door
    let since: Date
    private var sampler = ScreenSampler()
    /// The newest frame not yet judged, with the way the screen was held.
    private var held: (frame: CVPixelBuffer, orientation: CGImagePropertyOrientation)?

    init(store: ScreenStore, door: ScreenStore.Door, since: Date) {
        self.store = store
        self.door = door
        self.since = since
    }

    mutating func frame(_ frame: CVPixelBuffer, orientation: CGImagePropertyOrientation, at now: Date) -> ScreenRefusal? {
        if sampler.early(at: now) {
            held = (frame, orientation)
            return nil
        }
        held = nil
        return keep(frame, orientation: orientation, at: now)
    }

    mutating func tick(at now: Date) -> ScreenRefusal? {
        guard store.beat(at: now, since: since, under: door) else { return .signedOut }
        guard let held, !sampler.early(at: now) else { return nil }
        self.held = nil
        return keep(held.frame, orientation: held.orientation, at: now)
    }

    /// Judges one frame and keeps it if it is one to keep.
    private mutating func keep(_ frame: CVPixelBuffer, orientation: CGImagePropertyOrientation, at now: Date) -> ScreenRefusal? {
        guard let taken = sampler.take(frame, orientation: orientation, at: now) else { return nil }
        do {
            if try store.keep(taken.jpeg, at: now, under: door) { sampler.kept(taken, at: now) }
            return nil
        } catch {
            return error
        }
    }
}
#endif
