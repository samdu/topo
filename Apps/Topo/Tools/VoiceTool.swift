import Foundation
import TopoTools

/// `topo voice`: the mind's hand on how this phone hears and speaks. Four settings, each read and
/// written in the defaults its reader reads, so the settings sheet shows a change at once:
/// Settings' Noise suppression (`NoiseSuppression`), which the microphone reads at each press,
/// Voice temperature (`VoiceTemperature`), which the voice reads as each sentence is asked for, so a change is the next reply's,
/// Call for spoken replies (`SpokenCallSetting`), which the call's driver reads as the phone locks,
/// Open mic waits (`QuietWait`), which the conversation's rule reads at each verdict,
/// and Earcons (`EarconsSetting`), which each cue reads as it sounds.
struct VoiceTool: Tool {
    /// The defaults are read and written from the service's own task; `UserDefaults` is safe there.
    private let defaults: Defaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = Defaults(store: defaults)
    }

    private struct Defaults: @unchecked Sendable { let store: UserDefaults }

    let name = "voice"
    let summary = "how this phone hears the person and speaks: the microphone's noise suppression, the voice's temperature, the call behind the lock, the open microphone's wait, the earcons"
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

    topo voice call [status]                whether a spoken reply behind the lock is a call
    topo voice call on                      it is: a card on the Lock Screen while you answer, hang up stops you
    topo voice call off                     no call: the wait behind the lock is capped at two minutes

    On unless turned off. A change applies from the next spoken reply, on this phone only, and
    they can change it back in Settings.

    topo voice wait [status]                how long a pause runs before Topo may decide you have finished
    topo voice wait VALUE                   set it: seconds from \(QuietWait.said(QuietWait.range.lowerBound)) to \(QuietWait.said(QuietWait.range.upperBound)), in a conversation behind the lock

    \(QuietWait.said(QuietWait.standard)) s unless changed. A pause that sounds unfinished is still waited through, up to 4 s. A
    change applies from the judge's next verdict, on this phone only, and they can change it back in Settings.

    topo voice earcons [status]             whether the spoken exchange sounds its cues
    topo voice earcons on                   it does: a tone as the microphone opens, as the words go,
                                            as a reply read aloud ends, and when a spoken turn fails
    topo voice earcons off                  no cues

    On unless turned off. A change applies from the next cue, on this phone only, and they can
    change it back in Settings.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count <= 2 else { return .usage(usage + "\n") }
        switch arguments.first {
        case "noise-suppression": return noiseSuppression(arguments)
        case "temperature": return temperature(arguments)
        case "call": return call(arguments)
        case "wait": return wait(arguments)
        case "earcons": return earcons(arguments)
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

    private func call(_ arguments: [String]) -> ToolReply {
        switch arguments.count == 2 ? arguments[1] : "status" {
        case "status":
            return .ok("call for spoken replies \(SpokenCallSetting.enabled(defaults.store) ? "on" : "off")\n")
        case "on", "off":
            let on = arguments[1] == "on"
            defaults.store.set(on, forKey: SpokenCallSetting.key)
            return .ok("call for spoken replies \(on ? "on" : "off"), from the next spoken reply\n")
        default:
            return .usage(usage + "\n")
        }
    }

    private func wait(_ arguments: [String]) -> ToolReply {
        guard arguments.count == 2, arguments[1] != "status" else {
            return .ok("wait \(QuietWait.said(QuietWait.value(defaults.store))) s\n")
        }
        // Judged as the rule judges what it reads, so nothing is kept that it would not wait for.
        guard let value = QuietWait.judged(Double(arguments[1])) else { return .usage(usage + "\n") }
        defaults.store.set(value, forKey: QuietWait.key)
        return .ok("wait \(QuietWait.said(value)) s, from the next verdict\n")
    }

    private func earcons(_ arguments: [String]) -> ToolReply {
        switch arguments.count == 2 ? arguments[1] : "status" {
        case "status":
            return .ok("earcons \(EarconsSetting.enabled(defaults.store) ? "on" : "off")\n")
        case "on", "off":
            let on = arguments[1] == "on"
            defaults.store.set(on, forKey: EarconsSetting.key)
            return .ok("earcons \(on ? "on" : "off"), from the next cue\n")
        default:
            return .usage(usage + "\n")
        }
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
