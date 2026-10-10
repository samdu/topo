import CoreMedia
import Foundation
import ImageIO
import ReplayKit

/// Topo's screen share: a broadcast the person starts from the system's own sheet, which hands
/// this extension every frame of the whole phone while it runs. It keeps stills in the app group
/// (`ScreenStore`) for the mind to look at through `topo screen`, chosen by `ScreenSampler`, and
/// nothing else: no video, no sound, no network, and nothing while the phone is signed out.
///
/// The system calls each of these in turn on one queue, so a frame that arrives while another is
/// being made into a still waits or is dropped by ReplayKit; nothing here runs two at once.
final class SampleHandler: RPBroadcastSampleHandler {
    private var store: ScreenStore?
    private var door: ScreenStore.Door?
    private var since = Date()
    private var beat = Date.distantPast
    private var sampler = ScreenSampler()

    /// How often the broadcast is marked as running, and the door read again.
    static let beatEvery: TimeInterval = 3

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date()
        guard let store = ScreenStore.shared(), let door = try? store.begin(at: now) else {
            return refuse(.signedOut)
        }
        self.store = store
        self.door = door
        since = now
        beat = now
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let store, let door, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if now.timeIntervalSince(beat) >= Self.beatEvery {
            beat = now
            guard store.beat(at: now, since: since, under: door) else { return refuse(.signedOut) }
        }
        guard let jpeg = sampler.take(frame, orientation: Self.orientation(of: sampleBuffer), at: now) else { return }
        do {
            try store.keep(jpeg, at: now, under: door)
        } catch {
            refuse(error)
        }
    }

    override func broadcastFinished() {
        store?.end()
    }

    /// Ends the broadcast, with the system showing the person why.
    private func refuse(_ refusal: ScreenRefusal) {
        store?.end()
        store = nil
        door = nil
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
