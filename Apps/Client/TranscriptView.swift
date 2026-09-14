import SwiftUI
import TopoCore

/// The transcript, read-only, on whatever screen it is given. The phone, the
/// watch and the TV all show the same turns in the same order; what changes
/// between them is the type size and how far the turns are from the edges.
struct TranscriptView: View {
    let turns: [Turn]
    var notice: String?
    /// What holding a turn offers. The default offers nothing, which is what a screen with no
    /// voice behind it — the watch, the television, a viewer — shows.
    var replay = Replay()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.spacing) {
                    if let notice {
                        Text(notice)
                            .font(Metrics.noticeFont)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(turns) { turn in
                        TurnRow(turn: turn, replay: replay).id(turn.ref)
                    }
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, Metrics.spacing)
                .frame(maxWidth: Metrics.maximumLineWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: turns.last?.ref) { _, _ in scroll(proxy, animated: true) }
        }
    }

    /// The newest turn is the one worth seeing, so the transcript opens at
    /// the end and follows it.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = turns.last?.ref else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

/// One turn: who said it, when, and what.
struct TurnRow: View {
    let turn: Turn
    var replay = Replay()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.role == .assistant ? "TOPO" : "YOU")
                    .font(Metrics.labelFont)
                    .foregroundStyle(turn.role == .assistant ? AnyShapeStyle(Theme.teal) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                Text(turn.at, format: .dateTime.hour().minute())
                    .font(Metrics.labelFont)
                    .foregroundStyle(.secondary)
            }
            Text(turn.text)
                .font(Metrics.bodyFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // Held, never tapped: a turn brushed in passing must not start talking. With nothing to
        // offer — a person's own turn, or a phone that cannot speak right now — the menu has no
        // items and the press does nothing.
        .contextMenu {
            if let offer = replay.offer(for: turn) {
                Button { offer.act() } label: { Label(offer.title, systemImage: offer.systemImage) }
            }
        }
        #endif
        #if os(tvOS)
        // The remote scrolls a tvOS list by moving focus, so every turn has
        // to be somewhere focus can land.
        .focusable()
        #endif
    }
}

/// Saying a turn again on demand. Only a spoken turn's reply is read aloud as it arrives, so a
/// typed turn's reply is silent; holding it is how it gets heard. The speaker belongs to the
/// chat screen and is threaded down to the rows from there, so nothing here reaches for it.
struct Replay {
    /// True while the speaker is reading something, whichever turn started it: the offer on
    /// every row is then the one that stops it, since two replies over each other is noise.
    var speaking = false
    /// Whether the phone can say anything at all. Speaking is foreground work — synthesis
    /// submits GPU commands and iOS kills a backgrounded process that does — so the offer is
    /// gone while the scene is not active. Which voice would say it does not come into it: the
    /// `AVSpeechSynthesizer` fallback is what a phone without the on-device model uses.
    var canSpeak = false
    var say: @MainActor (String) -> Void = { _ in }
    var stopSpeaking: @MainActor () -> Void = {}

    /// What holding `turn` offers, or nothing at all. A person's own turn offers nothing: their
    /// words are not Topo's to say.
    func offer(for turn: Turn) -> Offer? {
        guard canSpeak, turn.role == .assistant else { return nil }
        if speaking {
            return Offer(title: "Stop", systemImage: "stop.fill", act: stopSpeaking)
        }
        return Offer(title: "Say again", systemImage: "speaker.wave.2", act: { say(turn.text) })
    }

    /// One menu item: what it reads and what it does.
    struct Offer {
        let title: String
        let systemImage: String
        let act: @MainActor () -> Void
    }
}

/// What differs between a watch, a phone and a television is the size of the
/// type and how much room the turns get. The transcript itself does not.
enum Metrics {
    #if os(watchOS)
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 2
    static let maximumLineWidth: CGFloat = .infinity
    static let labelFont = Font.system(.caption2).weight(.semibold)
    static let bodyFont = Font.system(.footnote)
    static let noticeFont = Font.system(.caption2)
    #elseif os(tvOS)
    static let spacing: CGFloat = 24
    static let horizontalPadding: CGFloat = 48
    static let maximumLineWidth: CGFloat = 1100
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.title3)
    static let noticeFont = Font.system(.caption)
    #else
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let maximumLineWidth: CGFloat = 672
    static let labelFont = Font.system(.caption).weight(.semibold)
    static let bodyFont = Font.system(.body)
    static let noticeFont = Font.system(.caption)
    #endif
}
