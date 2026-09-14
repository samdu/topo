// The microphone lane's feeder: loops a fixture into the default output (BlackHole on the CI
// runner) from one long-lived engine, and listens to the default input (the same loopback) in
// the same process. Every half second it writes a heartbeat and the input's level over the last
// three seconds, longer than one loop of the fixture and its silences. When that level is silent,
// or the engine's configuration changes (a device came or went), it restarts the engine and logs
// why. CI tooling for scripts/ci-audio-lane.sh, never bundled.
//
//   ci-audio-feeder <fixture.wav> <state directory>
import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: ci-audio-feeder <fixture> <state directory>\n".utf8))
    exit(2)
}
let fixture = URL(fileURLWithPath: arguments[1])
let state = URL(fileURLWithPath: arguments[2], isDirectory: true)
let logURL = state.appendingPathComponent("feeder.log")

func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let data = Data("\(stamp) \(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

func write(_ name: String, _ value: String) {
    try? value.write(to: state.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

/// Sums of squares per half second, over the last six: the input's level across three seconds.
final class Level: @unchecked Sendable {
    private let lock = NSLock()
    private var squares = 0.0, frames = 0
    private var windows: [(Double, Int)] = []

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        var sum = 0.0
        for i in 0..<n { sum += Double(channel[0][i] * channel[0][i]) }
        lock.withLock { squares += sum; frames += n }
    }

    /// Closes the current half second and returns the RMS over the last three, and whether any
    /// audio at all arrived in this half second.
    func roll() -> (rms: Double, arrived: Bool) {
        lock.withLock {
            windows.append((squares, frames))
            if windows.count > 6 { windows.removeFirst() }
            let arrived = frames > 0
            squares = 0; frames = 0
            let total = windows.reduce((0.0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
            return (total.1 > 0 ? (total.0 / Double(total.1)).squareRoot() : 0, arrived)
        }
    }

    func reset() { lock.withLock { squares = 0; frames = 0; windows = [] } }
}

let file: AVAudioFile
let buffer: AVAudioPCMBuffer
do {
    file = try AVAudioFile(forReading: fixture)
    guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        log("could not allocate the fixture buffer"); exit(1)
    }
    try file.read(into: b)
    buffer = b
} catch {
    log("could not read the fixture: \(error)"); exit(1)
}

let level = Level()
var engine = AVAudioEngine()
var player = AVAudioPlayerNode()
var configurationChanged = false
var observer: NSObjectProtocol?

func startEngine(_ why: String) -> Bool {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    engine.stop()
    engine = AVAudioEngine()
    player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        log("\(why): the default input has no format"); return false
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { tapped, _ in level.add(tapped) }
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
        configurationChanged = true
    }
    do {
        try engine.start()
    } catch {
        log("\(why): the engine did not start: \(error)"); return false
    }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    level.reset()
    log("\(why): playing \(fixture.lastPathComponent) on a loop at \(format.sampleRate) Hz input")
    return true
}

var running = startEngine("start")
var silentWindows = 0
var ticks = 0
while true {
    Thread.sleep(forTimeInterval: 0.5)
    ticks += 1
    let (rms, arrived) = level.roll()
    write("heartbeat", String(Int(Date().timeIntervalSince1970)))
    write("level", String(format: "%.4f", rms))
    if !running {
        if ticks % 4 == 0 { running = startEngine("retry") }
        continue
    }
    if configurationChanged {
        configurationChanged = false
        running = startEngine("restart after an audio configuration change")
        silentWindows = 0
        continue
    }
    // Six windows fill the three seconds; judge only once they have.
    silentWindows = (rms < 0.005 || !arrived) ? silentWindows + 1 : 0
    if silentWindows >= 6 {
        log(String(format: "restart: the input was silent for 3 s (rms %.4f, audio arriving: %@)", rms, arrived ? "yes" : "no"))
        running = startEngine("restart after silence")
        silentWindows = 0
    }
}
