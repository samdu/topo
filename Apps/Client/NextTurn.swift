#if os(iOS)
import Foundation
import Observation
import TopoCore

/// The person's next turn, at the end of the transcript: what is written in the row, whether the
/// keyboard has it, and the nonce of the turn those words are on their way under.
///
/// It is a type of its own rather than the chat screen's own state because what the row holds
/// outlives the screen. Words said and not yet in the log survive the app being killed, in the
/// harness's line, and the chat that comes back is a fresh screen with fresh state: the row it
/// draws is resumed from that line (`resume(from:)`) so it is the row the turn was sent from,
/// with the words still in it and the way back from them still offered. That is also why the
/// rules about those words live here and not in a view — the row draws the words being sent,
/// until they land or are taken back, so `edit(_:in:)` refuses a landed turn's words while a turn
/// is on its way.
@MainActor
@Observable
final class NextTurn {
    /// What is written in the row: typed, heard by the microphone, or a landed turn's words taken
    /// back to be changed.
    var text = ""
    /// The keyboard is up, so the row has it. The control on the glass raises it and the keyboard
    /// going down by itself lowers it, so it is written from both ends.
    var typing = false
    /// The nonce of the turn the row's words were said under, while they are on their way. Nil
    /// when nothing in the row has been said.
    private(set) var sent: String?

    /// The row is holding a turn on its way: said, and not in the log. A turn whose reply failed
    /// is in the log like any other, so this ends with the words landing and not with the reply.
    func sending(in harness: Harness) -> Bool {
        guard let sent else { return false }
        return !harness.said(sent)
    }

    /// Puts what is written on the line and holds it in the row until it lands, and answers the
    /// nonce it went under. Nothing at all for a row holding nothing but space.
    @discardableResult
    func send(via harness: Harness) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let nonce = harness.willSend(text)
        sent = nonce
        return nonce
    }

    /// The same for words the microphone heard: they stand in the row as the turn on its way
    /// rather than vanishing between the release and the log, so the bubble being written in is
    /// the bubble that lands.
    @discardableResult
    func send(heard: String, via harness: Harness) -> String? {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        text = heard
        return send(via: harness)
    }

    /// The turn the row is holding has reached the log, so the row is done with it — answered, or
    /// answered by nothing, which are the same thing to the row: the words are said either way
    /// and a second send would be a second turn. Answers whether it was holding one.
    @discardableResult
    func clearIfLanded(in harness: Harness) -> Bool {
        guard let sent, harness.said(sent) else { return false }
        text = ""
        self.sent = nil
        return true
    }

    /// What the row takes back up when the chat appears: the oldest words on the line whose turn
    /// the read did not find in the log, under the nonce they were first said with, so an app
    /// killed with words on the line comes back to the row they were sent from rather than to an
    /// empty one — which is where the way back from a turn that never landed is offered, and
    /// where it is most needed.
    ///
    /// The oldest still owed, and not the head of the line: the head can be a turn that reached
    /// the log and lost its acknowledgement, which the retry settles without saying anything
    /// more, while a turn said behind it — the chat lets a second press append while one is in
    /// flight — is still owed and is what the row has to draw. Words already in the log belong to
    /// the transcript and not to the row, whichever entry they are.
    ///
    /// Nothing when nothing on the line is still owed, and nothing when the row already holds
    /// something, which is a screen that has not been away.
    @discardableResult
    func resume(from harness: Harness) -> Bool {
        guard sent == nil, text.isEmpty else { return false }
        guard let owed = harness.owed.first(where: { !harness.said($0.nonce) }) else { return false }
        text = owed.text
        sent = owed.nonce
        return true
    }

    /// Holding one of the person's own landed turns puts its words back in the row, to be changed
    /// and said again; the log is append-only, so this edits what is said next and never the turn
    /// that was said. Refused while the row is holding a turn on its way: those words are the
    /// words being sent, and a row that drew something else would send one turn and show another.
    /// Answers whether it took them.
    @discardableResult
    func edit(_ turn: Turn, in harness: Harness) -> Bool {
        guard !sending(in: harness) else { return false }
        text = turn.text
        typing = true
        return true
    }

    /// Whether there is a way back from the turn the row is holding, which is what decides whether
    /// holding the row offers one. `withdraw` asks the log itself before it acts.
    func canWithdraw(in harness: Harness) -> Bool {
        guard let sent else { return false }
        return harness.canWithdraw(sent)
    }

    /// The way back from a turn that never reached the log: the words come off the line and stay
    /// in the row to be changed, so what is said again is one turn under one nonce. Answers the
    /// nonce taken back — a turn nothing is coming for — or nothing when the log refused it.
    func withdraw(via harness: Harness) async -> String? {
        guard let nonce = sent, harness.canWithdraw(nonce) else { return nil }
        guard await harness.withdraw(nonce) else { return nil }
        sent = nil
        typing = true
        return nonce
    }
}
#endif
