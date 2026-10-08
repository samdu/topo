#if os(iOS)
import Foundation

/// Where what a session of the microphone hears goes, which is settled once, as the session
/// begins, and kept to its end: the press that opens the microphone decides it, and the release
/// — or the press that closes a hands-free one — follows it whatever the pane has become since.
///
/// A session begun with the pane at rest is a spoken turn: what is heard replaces the draft as
/// its caption, and the release sends it. One begun over the row is dictation into the draft:
/// what is heard is written after what was there when the press began, and the release sends
/// nothing — the send in the glass does, as a typed turn.
struct Dictation: Equatable, Sendable {
    /// What was written when a session began over the row; nil for a spoken turn.
    var over: String?
    /// What the session last wrote into the draft; nil until it has written.
    var wrote: String?

    /// A spoken turn.
    static let spoken = Dictation(over: nil)

    /// The release sends what was heard.
    var sends: Bool { over == nil }

    /// What the draft holds once `heard` has been heard.
    func written(hearing heard: String) -> String {
        guard let over else { return heard }
        return Self.join(over, heard)
    }

    /// What was heard after what was written, with one space between them and none where either
    /// is empty; what was written keeps a space or a line it already ends with.
    static func join(_ written: String, _ heard: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return written }
        guard let last = written.last else { return heard }
        return last.isWhitespace ? written + heard : written + " " + heard
    }

    /// Whether the draft, holding `current`, is still as a dictation left it: what it last wrote,
    /// or what was there when it began. Anything else is the person's typing since, and the
    /// draft is then theirs: a caption written after what the session began over would take
    /// their words out, so the session writes nothing more and is ended. A spoken turn's draft
    /// is the session's own throughout.
    func standing(in current: String) -> Bool {
        guard let over else { return true }
        return current == (wrote ?? over)
    }

    /// Whether a press on the microphone, drawn as `drawn`, begins a session: a press down on a
    /// microphone that is not open and is not Stop. Its release, and the press that closes a
    /// microphone left open, belong to the session already begun.
    static func begins(down: Bool, drawn: Composer.MicState) -> Bool {
        down && !drawn.open && drawn.appearance != .stop
    }
}
#endif
