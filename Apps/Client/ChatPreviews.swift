#if DEBUG && os(iOS)
import SwiftUI
import TopoCore

/// Fixture turns for the canvas: a conversation the log could have held, with no CloudKit,
/// harness or voice behind it. Debug builds only, so nothing here ships.
enum PreviewTurns {
    static let phone = DeviceID("preview-phone")
    static let hub = DeviceID("preview-hub")

    static let short: [Turn] = make([
        (.person, "What's the capital of France?"),
        (.assistant, "Paris."),
    ])

    static let long: [Turn] = make([
        (.person, "Morning. What's on today?"),
        (.assistant, "Two things: the dentist at 11, and Krista wanted to talk about the garden when you're back. Nothing else on the calendar."),
        (.person, "Remind me to pick up Daphne's food on the way home."),
        (.assistant, "Done. It'll pop up when you leave the dentist."),
        (.person, "Reminder: pick up Daphne's food."),
        (.person, "Krista's Topo: she's running 20 minutes late for dinner, can you let Sam know?"),
        (.assistant, "Two things came in: your reminder about Daphne's food, and Krista says she'll be 20 minutes late for dinner."),
        (.person, "Can you explain, briefly, why the sky is blue but sunsets are red? I keep forgetting."),
        (.assistant, "Air scatters short wavelengths more than long ones, so blue light bounces around the whole sky. At sunset the light crosses far more air on its way to you, and by then most of the blue has scattered away, leaving the reds and oranges that travel straighter."),
        (.person, "ta"),
        (.assistant, "Any time."),
    ])

    @MainActor static let question = Question(
        header: "Dinner",
        text: "Krista's 20 minutes late. Do you want me to push the reservation, or hold it and let them know you'll be two at first?",
        options: [
            .init(label: "Push it", description: "Move the table to 7:50 and tell Krista the new time"),
            .init(label: "Hold it", description: "Keep 7:30, ask them to seat you and Natasha first"),
            .init(label: "Ask Krista", description: "She might prefer to meet you there later"),
        ])

    /// The turns that were not the person's own, by the words they start with.
    static func origin(of turn: Turn) -> String? {
        guard turn.role == .person else { return nil }
        if turn.text.hasPrefix("Reminder:") { return "Reminder" }
        if turn.text.hasPrefix("Krista's Topo:") { return "Krista's Topo" }
        return nil
    }

    private static func make(_ lines: [(TurnRole, String)]) -> [Turn] {
        var turns: [Turn] = []
        var previous: TurnRef?
        for (index, (role, text)) in lines.enumerated() {
            let ref = TurnRef(device: role == .person ? phone : hub, sequence: Int64(index + 1))
            let at = Date(timeIntervalSinceNow: Double(index - lines.count) * 90)
            turns.append(Turn(ref: ref, parents: previous.map { [$0] } ?? [], role: role, text: text, at: at))
            previous = ref
        }
        return turns
    }
}

#Preview("Transcript") {
    @Previewable @State var turnCount = 8
    @Previewable @State var notice = false
    @Previewable @State var speaking = false

    VStack(spacing: 0) {
        TranscriptView(turns: Array(PreviewTurns.long.prefix(turnCount)),
                       notice: notice ? "Topo is on another device; this one shows what it says." : nil,
                       replay: Replay(speaking: speaking, canSpeak: true),
                       origin: PreviewTurns.origin)
        Divider()
        VStack(alignment: .leading) {
            Stepper("Turns: \(turnCount)", value: $turnCount, in: 0...PreviewTurns.long.count)
            Toggle("Notice", isOn: $notice)
            Toggle("Speaking", isOn: $speaking)
        }
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
    }
}
#endif
