import CoreMedia
import Foundation
import ImageIO
import ReplayKit

/// Topo's screen share: a broadcast the person starts from the system's own sheet, which hands
/// this extension every frame of the whole phone while it runs. It keeps stills in the app group
/// (`ScreenStore`) for the mind to look at through `topo screen`, chosen by `ScreenSampler`, and
/// nothing else: no video, no sound, no network, and nothing while the phone is signed out.
///
/// ReplayKit sends frames as the screen changes and none while it rests, so a clock of the
/// extension's own does what cannot wait for a frame: it marks the broadcast as running, reads
/// the door again, so a sign-out ends a share of a resting screen, and judges the one frame held
/// back, which is the last to arrive inside the interval since a still and so the screen as it
/// came to rest. The clock and ReplayKit's queue take turns under one lock.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var store: ScreenStore?
    private var door: ScreenStore.Door?
    private var since = Date()
    private var sampler = ScreenSampler()
    /// The newest frame not yet judged, with the way the screen was held: one at a time.
    private var held: (frame: CVPixelBuffer, orientation: CGImagePropertyOrientation)?
    private var clock: DispatchSourceTimer?

    /// How often the clock ticks: the broadcast is marked as running, the door read again, and
    /// the frame held back judged.
    static let tick: TimeInterval = ScreenSampler.interval

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date()
        guard let store = ScreenStore.shared(), let door = try? store.begin(at: now) else {
            return refuse(.signedOut)
        }
        let clock = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zone.hexagon.topo.broadcast.clock"))
        clock.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
        clock.setEventHandler { [weak self] in self?.ticked() }
        lock.withLock {
            self.store = store
            self.door = door
            since = now
            self.clock = clock
        }
        clock.resume()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = Self.orientation(of: sampleBuffer), now = Date()
        let refusal: ScreenRefusal? = lock.withLock {
            guard store != nil else { return nil }
            if sampler.early(at: now) {
                held = (frame, orientation)
                return nil
            }
            held = nil
            return keep(frame, orientation: orientation, at: now)
        }
        if let refusal { refuse(refusal) }
    }

    private func ticked() {
        let now = Date()
        let refusal: ScreenRefusal? = lock.withLock {
            guard let store, let door else { return nil }
            guard store.beat(at: now, since: since, under: door) else { return .signedOut }
            guard let held, !sampler.early(at: now) else { return nil }
            self.held = nil
            return keep(held.frame, orientation: held.orientation, at: now)
        }
        if let refusal { refuse(refusal) }
    }

    /// Judges one frame and keeps it if it is one to keep. Called under the lock.
    private func keep(_ frame: CVPixelBuffer, orientation: CGImagePropertyOrientation, at now: Date) -> ScreenRefusal? {
        guard let store, let door, let taken = sampler.take(frame, orientation: orientation, at: now) else { return nil }
        do {
            if try store.keep(taken.jpeg, at: now, under: door) { sampler.kept(taken, at: now) }
            return nil
        } catch {
            return error
        }
    }

    override func broadcastFinished() {
        stop()
    }

    /// The broadcast is over: the clock stops, it is no longer live, and no frame is held.
    private func stop() {
        lock.withLock {
            clock?.cancel()
            clock = nil
            store?.end()
            store = nil
            door = nil
            held = nil
        }
    }

    /// Ends the broadcast, with the system showing the person why.
    private func refuse(_ refusal: ScreenRefusal) {
        stop()
        finishBroadcastWithError(NSError(domain: "zone.hexagon.topo.broadcast", code: 1, userInfo: [
            NSLocalizedDescriptionKey: refusal.words,
            NSLocalizedFailureReasonErrorKey: refusal.words,
        ]))
    }

    /// The way the screen was held when the frame was made, which ReplayKit attaches to it.
    static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) else { return .up }
        return orientation
    }
}
