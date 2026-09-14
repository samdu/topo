import Foundation

/// Stage one of pacing a Pocket clip: shorten the gaps, leave the speech alone. Kokoro's pace
/// knob mostly takes its time out of the pauses, and a uniform time-stretch takes it out of the
/// words instead, which is audible and which Sam rejected. Measured on one script, Pocket carries
/// 3.0s of inter-phrase pause against Kokoro's 1.2s, so most of what a listener waits for is
/// silence. This does what the knob does: 20ms RMS frames, a frame is silent below
/// max(2% of the loudest frame, 1e-4); an inner run of silent frames longer than the 0.15s cap
/// loses its excess from the middle of the run, so the decay of the word before and the onset
/// of the word after both survive; and the head and tail keep up to 0.05s each, so consecutive
/// sentences of a streamed reply meet with about 0.10s between them, Kokoro's own median gap,
/// rather than butting together. Stage two is the play queue's time-pitch unit at `Voice.tempo`,
/// which after this is a small stretch rather than a large one.
///
/// Same arithmetic as the reference `trim.py`, except at the edges. `0.05 / 0.02` is 2.5 frames,
/// and Python's `round` gives 2 where Swift's `.rounded()` gives 3, so the reference keeps 0.04s;
/// here the counts round up to whole frames, so the edge is three frames (0.06s, the first whole
/// number of frames covering 0.05s) and the cap eight (0.16s). A clip trimmed here is one frame
/// longer at each edge than the reference's, which is intended.
enum PocketPace {
    static let frame = 0.02
    static let cap = 0.15
    static let edge = 0.05
    /// In frames: the cap is 8 and the edge 3.
    static let capFrames = Int((cap / frame).rounded(.up))
    static let edgeFrames = Int((edge / frame).rounded(.up))

    static func trimGaps(_ y: [Float], rate: Int) -> [Float] {
        let win = Int(frame * Double(rate))
        guard win > 0, y.count >= win else { return y }
        let n = y.count / win
        var rms = [Float](repeating: 0, count: n)
        for f in 0 ..< n {
            var acc: Float = 0
            for i in f * win ..< (f + 1) * win { acc += y[i] * y[i] }
            rms[f] = (acc / Float(win)).squareRoot()
        }
        let threshold = max((rms.max() ?? 0) * 0.02, 1e-4)
        let quiet = rms.map { $0 < threshold }
        guard let head = quiet.firstIndex(of: false),
              let tail = quiet.lastIndex(of: false) else { return y }

        var keep = [Bool](repeating: false, count: n)
        for f in head ... tail { keep[f] = true }
        var i = head
        while i <= tail {
            guard quiet[i] else { i += 1; continue }
            var j = i
            while j <= tail && quiet[j] { j += 1 }
            let run = j - i
            if run > capFrames {
                let cut = run - capFrames
                let start = i + (run - cut) / 2
                for f in start ..< start + cut { keep[f] = false }
            }
            i = j
        }

        var out: [Float] = []
        out.reserveCapacity(y.count)
        out.append(contentsOf: y[max(0, head - edgeFrames) * win ..< head * win])
        for f in head ... tail where keep[f] {
            out.append(contentsOf: y[f * win ..< (f + 1) * win])
        }
        out.append(contentsOf: y[(tail + 1) * win ..< min(n, tail + 1 + edgeFrames) * win])
        return out
    }
}
