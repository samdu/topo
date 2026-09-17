import Foundation

/// Stage one of pacing a Pocket sentence: shorten the gaps, leave the speech alone. Kokoro's pace
/// knob mostly takes its time out of the pauses, and a uniform time-stretch takes it out of the
/// words instead, which is audible and which Sam rejected. Measured on one script, Pocket carries
/// 3.0s of inter-phrase pause against Kokoro's 1.2s, so most of what a listener waits for is
/// silence. This does what the knob does: 20ms RMS windows, a window being quiet when its RMS is
/// below 2% of the loudest window heard so far in this reply *or* below the absolute floor of
/// 1e-4; an inner run of silent windows longer than the cap of eight windows, 0.16s, loses
/// its excess from the middle of the run, so the decay of the word before and the onset of the
/// word after both survive; and the head and tail keep up to 0.05s each, so consecutive sentences
/// of a streamed reply meet with about 0.10s between them, Kokoro's own median gap, rather than
/// butting together. Stage two is the play queue's time-pitch unit at `Voice.tempo`, which after
/// this is a small stretch rather than a large one.
///
/// It runs on the frames as they decode, so a trimmer is a value with state rather than a
/// function over a finished clip, and `loudest` is the loudest window heard so far rather than
/// the loudest in the sentence. Its scope is one reply: `Speaker` carries `loudest` from each
/// sentence into the next and starts it again at every `speak`, so one voice at one level is
/// judged on one scale and nothing an earlier reply was loud at judges a later one. That makes
/// it a different function from a cut over the whole clip, not an approximation of one: a reply
/// that opens quietly has heard nothing louder yet, so its opening counts as speech and is kept
/// where a cut that knew the sentence would have trimmed it, while the same quiet opening in the
/// reply's second sentence is a gap, because the reply's peak is by then known.
///
/// The floor is what keeps that relative rule honest at the bottom of the scale: 2% of near
/// silence is still near silence, and without it a reply opening on dither would be its own
/// loudest window and kept as speech. Anything under 1e-4 is digital near silence, and silence
/// whatever has been heard.
///
/// Silence is held rather than emitted, because a gap is only known to be a gap once speech
/// lands after it; a held run then releases its first `cap / 2` and last `cap / 2` windows,
/// which is the middle cut, or all of it when there was no middle to cut. Speech is never
/// delayed — the window that ends a gap goes out in the same frame it arrived in — so the hold
/// costs nothing a listener can hear.
///
/// The counts are whole windows, rounded up from the durations they are written as: `0.05 / 0.02`
/// is 2.5, so the edge is three windows, 0.06s, and `0.15 / 0.02` is 7.5, so the cap is eight,
/// 0.16s. What the trimmer cuts to is the window count, which is what these say.
struct PocketPace {
    static let frame = 0.02
    static let cap = 0.15
    static let edge = 0.05
    /// In windows: the cap is 8 and the edge 3.
    static let capFrames = Int((cap / frame).rounded(.up))
    static let edgeFrames = Int((edge / frame).rounded(.up))

    /// The loudest window seen, carried across sentences by the caller.
    private(set) var loudest: Float
    /// Samples cut, for the log line.
    private(set) var dropped = 0

    private var started = false
    /// Silent windows behind the last speech that have not gone out.
    private var held: [[Float]] = []
    /// Silent windows already sent from the current run.
    private var sent = 0
    /// Samples left over from a frame that was not a whole number of windows.
    private var rest: [Float] = []

    init(loudest: Float = 0) { self.loudest = loudest }

    /// The part of this frame that goes to the speaker now.
    mutating func take(_ samples: [Float], rate: Int) -> [Float] {
        let win = Int(Self.frame * Double(rate))
        guard win > 0 else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count + rest.count)
        let buf = rest + samples
        var i = 0
        while i + win <= buf.count {
            let window = Array(buf[i ..< i + win])
            i += win
            var acc: Float = 0
            for x in window { acc += x * x }
            let rms = (acc / Float(win)).squareRoot()
            loudest = max(loudest, rms)
            if rms < max(loudest * 0.02, 1e-4) {
                if !started {
                    // Leading silence: only the last `edge` windows survive.
                    held.append(window)
                    if held.count > Self.edgeFrames { dropped += held.removeFirst().count }
                } else if sent < Self.edgeFrames {
                    sent += 1
                    out.append(contentsOf: window)
                } else {
                    held.append(window)
                }
            } else {
                started = true
                out.append(contentsOf: release())
                out.append(contentsOf: window)
            }
        }
        rest = Array(buf[i...])
        return out
    }

    /// The gap ended: what survives of it. The `edge` windows already sent plus these make the
    /// first `cap / 2` and the last `cap / 2` of a long run, and every window of a short one.
    private mutating func release() -> [Float] {
        defer { held.removeAll(); sent = 0 }
        let head = Self.capFrames / 2 - Self.edgeFrames
        let tail = Self.capFrames / 2
        guard held.count > head + tail else { return held.flatMap { $0 } }
        for window in held[head ..< held.count - tail] { dropped += window.count }
        return (held[..<head] + held[(held.count - tail)...]).flatMap { $0 }
    }

    /// The sentence is over. The tail keeps the `edge` windows that have already gone out; the
    /// held remainder and whatever sample fragment was waiting for a whole window are dropped.
    mutating func finish() {
        for window in held { dropped += window.count }
        held.removeAll()
        dropped += rest.count
        rest.removeAll()
    }
}
