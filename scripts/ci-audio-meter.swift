// Measures the host's default audio input for a number of seconds: one line,
// "auth=<AVAuthorizationStatus raw> rate=<Hz> buffers=<n> frames=<n> rms=<x> peak=<x>".
// CI tooling for scripts/ci-audio-lane.sh: says whether audio is flowing on the loopback itself.
import AVFoundation
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 1 : 1
let auth = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.sampleRate > 0, format.channelCount > 0 else {
    print("auth=\(auth) rate=0 buffers=0 frames=0 rms=0 peak=0 (no input format)")
    exit(0)
}
final class Tally: @unchecked Sendable {
    let lock = NSLock()
    var buffers = 0, frames = 0
    var squares = 0.0, peak: Float = 0
}
let tally = Tally()
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let channel = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    var sum = 0.0
    var top: Float = 0
    for i in 0..<n {
        let v = channel[0][i]
        sum += Double(v * v)
        top = max(top, abs(v))
    }
    tally.lock.withLock {
        tally.buffers += 1
        tally.frames += n
        tally.squares += sum
        tally.peak = max(tally.peak, top)
    }
}
do {
    try engine.start()
} catch {
    print("auth=\(auth) rate=\(format.sampleRate) buffers=0 frames=0 rms=0 peak=0 (engine did not start: \(error))")
    exit(0)
}
Thread.sleep(forTimeInterval: seconds)
engine.stop()
tally.lock.withLock {
    let rms = tally.frames > 0 ? (tally.squares / Double(tally.frames)).squareRoot() : 0
    print(String(format: "auth=%d rate=%.0f buffers=%d frames=%d rms=%.4f peak=%.4f", auth, format.sampleRate, tally.buffers, tally.frames, rms, tally.peak))
}
