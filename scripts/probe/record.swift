import AVFoundation
// Records the host default input for 3 s and prints buffers, frames and RMS.
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
print("host input format: \(format)")
guard format.sampleRate > 0, format.channelCount > 0 else { print("host: no input"); exit(0) }
var buffers = 0, frames = 0
var sumSq: Double = 0
let lock = NSLock()
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
    lock.lock(); defer { lock.unlock() }
    buffers += 1; frames += Int(buf.frameLength)
    if let ch = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { sumSq += Double(ch[0][i] * ch[0][i]) } }
}
do { try engine.start() } catch { print("host: engine start failed \(error)"); exit(0) }
Thread.sleep(forTimeInterval: 3)
engine.stop()
lock.lock()
print("host: buffers=\(buffers) frames=\(frames) rms=\(frames > 0 ? (sumSq / Double(frames)).squareRoot() : 0)")
lock.unlock()
