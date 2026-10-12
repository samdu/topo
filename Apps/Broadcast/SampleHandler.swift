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
/// extension's own does what cannot wait for a frame (`ScreenWatch.tick`): it marks the broadcast
/// as running, reads the door again, so a sign-out ends a share of a resting screen, and judges
/// the one frame held back. The clock and ReplayKit's queue take turns under one lock.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var watch: ScreenWatch?
    private var clock: DispatchSourceTimer?

    /// How often the clock ticks.
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
            watch = ScreenWatch(store: store, door: door, since: now)
            self.clock = clock
        }
        clock.resume()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = Self.orientation(of: sampleBuffer), now = Date()
        if let refusal = lock.withLock({ watch?.frame(frame, orientation: orientation, at: now) }) { refuse(refusal) }
    }

    private func ticked() {
        let now = Date()
        if let refusal = lock.withLock({ watch?.tick(at: now) }) { refuse(refusal) }
    }

    override func broadcastFinished() {
        stop()
    }

    /// The broadcast is over: the clock stops, it is no longer live, and no frame is held.
    private func stop() {
        lock.withLock {
            clock?.cancel()
            clock = nil
            watch?.store.end()
            watch = nil
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
