import Foundation
import TopoTools

/// `topo voice`: the mind's hand on how this phone hears. One setting, Settings' Noise suppression
/// (`NoiseSuppression`), read and written in the defaults the microphone reads at each press, so a
/// change is the next press's and the settings sheet's toggle shows it at once.
struct VoiceTool: Tool {
    /// The defaults are read and written from the service's own task; `UserDefaults` is safe there.
    private let defaults: Defaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = Defaults(store: defaults)
    }

    private struct Defaults: @unchecked Sendable { let store: UserDefaults }

    let name = "voice"
    let summary = "how this phone hears the person: noise suppression on the microphone"
    let usage = """
    topo voice noise-suppression [status]   whether the microphone is cleaned up before it is heard
    topo voice noise-suppression on         clean it up: Apple's voice processing (noise suppression, echo
                                            cancellation, gain control), for a bus, a street, a room with music
    topo voice noise-suppression off        the microphone as it comes

    On unless turned off. A change applies from the person's next press of the microphone, on this
    phone only, and they can change it back in Settings.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.first == "noise-suppression", arguments.count <= 2 else { return .usage(usage + "\n") }
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
}
