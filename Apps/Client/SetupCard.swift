#if os(iOS)
import SwiftUI

/// What a new install is still fetching and preparing, in three lines: the guest Topo works in,
/// the ear and the voice. It reads the state each part already keeps and holds none of its own.
enum Setup {
    struct Line: Equatable, Identifiable {
        let title: String
        let state: State
        var id: String { title }
    }

    enum State: Equatable {
        /// Not begun, or held up: the words say which.
        case waiting(String)
        /// Downloading, with the share of its bytes on the phone.
        case progress(Double, String)
        /// A step with no measure: an import, a model compiled for this phone.
        case working(String)
        case done
        case failed(String)
    }

    /// What a set of downloads has to say for a part that is fetching.
    struct Fetch: Equatable {
        var fraction: Double?
        var words: String
    }

    /// The ear's and the voice's steps, which are the same five.
    enum Stage: Equatable { case cold, fetching, loading, ready, failed(String) }

    static let workspace = "Topo's workspace"
    static let hearing = "Hearing you"
    static let speaking = "Speaking"

    static func lines(phase: Userland.Phase, claude: Userland.ClaudePhase, workspace: Fetch,
                      ear: Stage, earFetch: Fetch, earLoading: String,
                      voice: Stage, voiceFetch: Fetch, voiceLoading: String) -> [Line] {
        [Line(title: Self.workspace, state: state(phase: phase, claude: claude, fetch: workspace)),
         Line(title: hearing, state: state(ear, fetch: earFetch, loading: earLoading)),
         Line(title: speaking, state: state(voice, fetch: voiceFetch, loading: voiceLoading))]
    }

    /// The card is drawn while any line is not done.
    static func shows(_ lines: [Line]) -> Bool { lines.contains { $0.state != .done } }

    /// Whether the lines are an install's and not a launch's: something is downloading, being
    /// unpacked, or failed. Every launch loads the ear and the voice, and that alone draws no
    /// card; once an install has drawn one it stands until every line is done (`standing`).
    static func installing(_ lines: [Line]) -> Bool {
        lines.contains { line in
            switch line.state {
            case .progress, .failed: true
            case .waiting(let words): !launchWords.contains(words)
            case .working: line.title == workspace
            case .done: false
            }
        }
    }

    /// Whether the card stands, given whether it stood a moment ago: it comes for an install and
    /// goes when every line is done, so the models' first preparing on this phone is under it.
    static func standing(_ lines: [Line], stood: Bool) -> Bool { shows(lines) && (stood || installing(lines)) }

    static let notStarted = "not started"
    /// What a part waiting says on a launch with nothing to fetch: not begun, or its files all on
    /// the phone and its own state a moment behind them.
    static let launchWords: Set<String> = [notStarted, ModelDownloads.downloaded]

    static func state(phase: Userland.Phase, claude: Userland.ClaudePhase, fetch: Fetch) -> State {
        // Every pair is named, so a phase added later is a line this has to be taught.
        switch (phase, claude) {
        case (.failed(let why), _), (_, .failed(let why)): return .failed(why)
        case (.importing, _): return .working("unpacking")
        case (.fetching, _), (_, .fetching): return fetching(fetch)
        case (.ready, .fetched): return .done
        }
    }

    static func state(_ stage: Stage, fetch: Fetch, loading: String) -> State {
        switch stage {
        case .cold: .waiting(notStarted)
        case .fetching: fetching(fetch)
        case .loading: .working(loading)
        case .ready: .done
        case .failed(let why): .failed(why)
        }
    }

    /// A download that failed is a failure, in the words the downloads have for it, though the
    /// part itself is still waiting on it.
    private static func fetching(_ fetch: Fetch) -> State {
        if fetch.words.hasPrefix(downloadFailed) { return .failed(String(fetch.words.dropFirst(downloadFailed.count))) }
        return fetch.fraction.map { .progress($0, fetch.words) } ?? .waiting(fetch.words)
    }

    static let downloadFailed = "download failed: "

    /// The lines as the app's own parts stand now.
    @MainActor
    static func lines(userland: Userland = .shared, ear: Ear, voice: Voice, downloads: ModelDownloads = .shared) -> [Line] {
        func fetch(_ ids: [String]) -> Fetch { Fetch(fraction: downloads.fraction(ids), words: downloads.describe(ids)) }
        return lines(phase: userland.phase, claude: userland.claude,
                     workspace: fetch([ModelManifest.rootfs, ModelManifest.shell, ModelManifest.claudeCode]),
                     ear: stage(ear.state, trouble: ear.trouble), earFetch: fetch(Ear.models),
                     earLoading: ear.progress.isEmpty ? Ear.preparing : "\(Ear.preparing): \(ear.progress)",
                     voice: stage(voice.state, trouble: voice.trouble), voiceFetch: fetch(Voice.models),
                     voiceLoading: Voice.preparing)
    }

    static func stage(_ state: Ear.State, trouble: String?) -> Stage {
        switch state {
        case .cold: .cold
        case .fetching: .fetching
        case .loading: .loading
        case .ready: .ready
        case .failed: .failed(trouble ?? "unknown")
        }
    }

    static func stage(_ state: Voice.State, trouble: String?) -> Stage {
        switch state {
        case .cold: .cold
        case .fetching: .fetching
        case .loading: .loading
        case .ready: .ready
        case .failed: .failed(trouble ?? "unknown")
        }
    }
}

/// The setup's lines, the done ones among them, drawn while any is not done: over the composer in
/// the chat while the keyboard is down, where an updated app that already has a log finds it,
/// and under the question on the first run. Whether it stands at all is `Setup.standing`.
struct SetupCard: View {
    var lines: [Setup.Line]
    @Environment(\.look) private var look

    var body: some View {
        if Setup.shows(lines) {
            VStack(alignment: .leading, spacing: look.setup.spacing) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: look.setup.lineSpacing) {
                        HStack {
                            Text(line.title).font(look.setup.titleFont)
                            Spacer()
                            // A step with no measure turns; a bar with no value would stand still.
                            if case .working = line.state { ProgressView().controlSize(.mini) }
                            Text(Self.words(line.state))
                                .font(look.setup.wordsFont)
                                .foregroundStyle(Self.failed(line.state) ? look.setup.troubleInk : look.setup.wordsInk)
                                .multilineTextAlignment(.trailing)
                        }
                        bar(line.state)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("setup-\(line.title)")
                }
            }
            .tint(look.setup.tint)
            .padding(.horizontal, look.setup.horizontalPadding)
            .padding(.vertical, look.setup.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(look.setup.surface)
            .accessibilityIdentifier("setup-card")
        }
    }

    @ViewBuilder private func bar(_ state: Setup.State) -> some View {
        switch state {
        case .progress(let fraction, _): ProgressView(value: min(max(fraction, 0), 1))
        case .working, .waiting, .done, .failed: EmptyView()
        }
    }

    static func words(_ state: Setup.State) -> String {
        switch state {
        case .waiting(let words), .progress(_, let words), .working(let words): words
        case .failed(let why): "failed: \(why)"
        case .done: "ready"
        }
    }

    static func failed(_ state: Setup.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
#endif
