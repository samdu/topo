import SwiftUI

/// A question Topo asks with the answers laid out to pick from: a short header on Topo's side,
/// then one card per option and an open one for an answer of the person's own. Picking one is
/// the person's turn; it lands as their bubble.
struct Question {
    var header: String
    var text: String
    var options: [Option]
    var allowsOther = true
    var pick: (String) -> Void = { _ in }
    /// The person wants to answer in their own words: the keyboard.
    var other: () -> Void = {}

    struct Option: Identifiable {
        var label: String
        var description: String
        var id: String { label }
    }
}

struct QuestionView: View {
    let question: Question
    @State private var picked: String?
    /// The picked answer has been sent: signal until it lands.
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.header.uppercased())
                .font(Metrics.labelFont)
                .foregroundStyle(Theme.primary)
            Text(question.text)
                .font(Metrics.bodyFont)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(question.options) { option in
                    card(option.label, option.description, systemImage: nil)
                }
                if question.allowsOther {
                    card("Other", "Answer in your own words", systemImage: "keyboard")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One answer, drawn as the turn it would be: a bubble on the person's side in the secondary
    /// colour. A tap picks it and brings up send beside it, as a draft has; send makes it go,
    /// signal while it is on its way and teal only by landing in the log. The others fold away.
    private func card(_ label: String, _ description: String, systemImage: String?) -> some View {
        let chosen = picked == label
        let accent = chosen && sent ? Theme.signal : Theme.secondary
        return HStack(alignment: .bottom, spacing: 8) {
            Button {
                guard !sent else { return }
                withAnimation(.easeInOut(duration: 0.15)) { picked = chosen ? nil : label }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(accent)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(label)
                            .font(Metrics.bodyFont)
                            .foregroundStyle(Theme.text)
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, Metrics.bubblePadding)
                .padding(.vertical, Metrics.bubblePadding * 0.7)
                .background(Bubble.fill(accent))
            }
            .buttonStyle(.plain)
            if chosen {
                ZStack {
                    if sent {
                        ProgressView().tint(Theme.secondary)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { sent = true }
                            if systemImage == nil { question.pick(label) } else { question.other() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send")
                    }
                }
                .frame(width: 36, height: 36)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .disabled(sent && !chosen)
        .opacity(!sent || chosen ? 1 : 0.3)
    }
}
