import Foundation
import TopoTools

/// `topo voice`: the mind's hand on how this phone hears and speaks. Three settings, each read
/// and written in the defaults its reader reads, so the settings sheet shows a change at once:
/// Settings' Noise suppression (`NoiseSuppression`), which the microphone reads at each press,
/// Voice temperature (`VoiceTemperature`), which the voice reads as each sentence is asked for, so
/// a change is the next reply's, and While Topo works (`WorkingSounds`), which the keeper's sounds
/// read at each sound.
struct VoiceTool: Tool {
    /// The defaults are read and written from the service's own task; `UserDefaults` is safe there.
    private let defaults: Defaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = Defaults(store: defaults)
    }

    private struct Defaults: @unchecked Sendable { let store: UserDefaults }

    let name = "voice"
    let summary = "how this phone hears the person and speaks: the microphone's noise suppression, the voice's temperature, the sounds while Topo works"
    let usage = """
    topo voice noise-suppression [status]   whether the microphone is cleaned up before it is heard
    topo voice noise-suppression on         clean it up: Apple's voice processing (noise suppression, echo
                                            cancellation, gain control), for a bus, a street, a room with music
    topo voice noise-suppression off        the microphone as it comes

    On unless turned off. A change applies from the person's next press of the microphone, on this
    phone only, and they can change it back in Settings.

    topo voice temperature [status]         how much chance your voice is drawn with
    topo voice temperature VALUE            set it: a number from \(VoiceTemperature.said(VoiceTemperature.range.lowerBound)) to \(VoiceTemperature.said(VoiceTemperature.range.upperBound)); lower is steadier, higher livelier

    \(VoiceTemperature.said(VoiceTemperature.standard)) unless changed. A change applies from the next reply read aloud, on this phone only, and they
    can change it back in Settings.

    topo voice working [status]             what a spoken turn sounds like while you work on it
    topo voice working off                  nothing until the reply
    topo voice working receipts             a short tone as you search the web, run a command or write prose, and one when the turn fails
    topo voice working sounds               the tones over a soft working bed until the reply begins

    Receipts unless changed. The sounds are the spoken turn's: nothing sounds unless one is being
    waited for aloud. A change applies from the next sound, on this phone only, and they can
    change it back in Settings.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count <= 2 else { return .usage(usage + "\n") }
        switch arguments.first {
        case "noise-suppression": return noiseSuppression(arguments)
        case "temperature": return temperature(arguments)
        case "working": return working(arguments)
        default: return .usage(usage + "\n")
        }
    }

    private func noiseSuppression(_ arguments: [String]) -> ToolReply {
        switch arguments.count == 2 ? arguments[1] : "status" {
        case "status":
            return .ok("noise suppression \(NoiseSuppression.enabled(defaults.store) ? "on" : "off")\n")
        case "on":
            return set(true)
        case "off":
            return set(false)
        default:
            return .usage(usage + "\n")
        }
    }

    private func set(_ on: Bool) -> ToolReply {
        defaults.store.set(on, forKey: NoiseSuppression.key)
        return .ok("noise suppression \(on ? "on" : "off"), from the next press\n")
    }

    private func working(_ arguments: [String]) -> ToolReply {
        guard arguments.count == 2, arguments[1] != "status" else {
            return .ok("working sounds \(WorkingSounds.mode(defaults.store).rawValue)\n")
        }
        // Judged as the sounds judge what they read, so nothing is kept that they would not play.
        guard let mode = WorkingSounds.Mode(rawValue: arguments[1]) else { return .usage(usage + "\n") }
        defaults.store.set(mode.rawValue, forKey: WorkingSounds.key)
        return .ok("working sounds \(mode.rawValue), from the next sound\n")
    }

    private func temperature(_ arguments: [String]) -> ToolReply {
        guard arguments.count == 2, arguments[1] != "status" else {
            return .ok("temperature \(VoiceTemperature.said(Double(VoiceTemperature.value(defaults.store))))\n")
        }
        // Judged as the voice judges what it reads, so nothing is kept that it would not speak at.
        guard let value = VoiceTemperature.judged(Double(arguments[1])) else { return .usage(usage + "\n") }
        defaults.store.set(value, forKey: VoiceTemperature.key)
        return .ok("temperature \(VoiceTemperature.said(value)), from the next reply\n")
    }
}
