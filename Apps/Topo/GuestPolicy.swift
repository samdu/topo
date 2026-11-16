import Foundation
import TopoUserland

/// Claude Code's managed settings in the guest (`Guest.managedSettings`), which hold a debug build
/// to Haiku past the resident's own `--model` (`ClaudeModel.pinned`): a policy Claude Code applies
/// to the session, its sub-agents, a `/model` typed into it and any claude the guest starts. A
/// debug build writes it and a release build takes it away, since the fakefs outlives an install
/// and a release build's slider is the person's. It is a file inside the guest, so a guest process
/// that rewrites it, or calls the API itself, gets past it; and a login whose organisation serves
/// remote managed settings that name models is ranked above it.
enum GuestPolicy {
    /// What a debug build writes: Haiku the one model, every other family refused.
    static let haikuOnly = #"{"availableModels":["haiku"],"enforceAvailableModels":true,"deniedModels":["opus","sonnet","fable"]}"#

    /// This build's settings: the pin in a debug build, none in a release one.
    static var forBuild: String? {
        #if DEBUG
        settings(debug: true)
        #else
        settings(debug: false)
        #endif
    }

    /// The settings a debug build or a release one writes.
    static func settings(debug: Bool) -> String? { debug ? haikuOnly : nil }

    /// Puts `settings` in place through `write`, at the boot and before any claude starts. A pin that
    /// cannot be written is the boot's failure, so no claude starts unpinned; a release build's
    /// removal that fails is said at error and the guest goes on, since what it leaves is at most a
    /// guest held to Haiku, not one let past a pin.
    static func apply(_ settings: String?, write: @Sendable (String?) async throws -> Void,
                      log: @Sendable (String) -> Void) async throws {
        do {
            try await write(settings)
        } catch where settings == nil {
            log("guest policy: the managed settings a debug build left could not be removed, so this build may be held to Haiku: \(error)")
        }
    }
}
