import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model as the guest's proxy reaches it: the names it goes by on the wire, and
/// `LocalModel`, the seam between the Messages API's shape (`OnDeviceUpstream`) and the framework
/// (`SystemLocalModel`), so the suite can stand a counting fake in the framework's place.
public enum OnDeviceModel {
    /// The model id Claude Code is launched with when the on-device model is chosen, and what a
    /// request's `model` names for the proxy to answer it on the phone.
    public static let id = "apple-on-device"

    /// What a phone with no Claude login hands Claude Code as its API key, so it starts and sends
    /// its requests. It is not a credential: a request carrying it is answered on the phone and is
    /// never sent upstream (`Forwarder.isLocal`).
    public static let placeholderKey = "topo-on-device"

    /// The environment a process asking the on-device model is launched with: every model Claude
    /// Code may ask besides its main one (a title, a summary, a sub-agent) is the on-device model
    /// too, so nothing it sends names a Claude model. `placeholder` adds the API key, for a phone
    /// with no Claude login.
    public static func environment(placeholder: Bool) -> [String: String] {
        var environment = Dictionary(uniqueKeysWithValues: modelVariables.map { ($0, id) })
        if placeholder { environment["ANTHROPIC_API_KEY"] = placeholderKey }
        return environment
    }

    /// The variables Claude Code 2.1.285 reads a model from.
    public static let modelVariables = [
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
    ]

    /// Why the on-device model cannot answer on this device now, in words for the screen, or nil
    /// when it can. Asked afresh each time: a model still downloading is ready later.
    public static func unavailability() -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return "Apple's on-device model needs iOS 26 or later." }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale() else {
                let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "")
                return "Apple's on-device model doesn't speak \(language ?? "this phone's language") yet."
            }
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use the on-device model."
        case .unavailable(.modelNotReady):
            return "Apple's on-device model is still downloading."
        case .unavailable:
            return "Apple's on-device model isn't available on this device."
        }
        #else
        return "Apple's on-device model isn't available on this device."
        #endif
    }
}

/// One turn of a conversation as the on-device model is handed it.
public struct LocalTurn: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String

    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

/// What the on-device model refused or could not do, sorted by what the person is told.
public enum LocalModelError: Error, Equatable {
    /// The model cannot run here now: the words say why.
    case unavailable(String)
    /// The model would not answer this (a guardrail, a language it does not speak): the words are
    /// the reply the person sees.
    case declined(String)
    /// What it was handed did not fit its window.
    case tooLong
    case failed(String)
}

/// The on-device model, as the proxy asks it.
public protocol LocalModel: Sendable {
    /// Why it cannot answer now, or nil when it can.
    func unavailability() async -> String?
    /// Its window, in tokens.
    func contextSize() async -> Int
    /// How many tokens `instructions`, `history` and `prompt` take of the window together.
    func tokenCount(instructions: String, history: [LocalTurn], prompt: String) async throws -> Int
    /// The reply to `prompt`, as the whole of it so far each time it grows. Cancelling the
    /// iteration ends the generation.
    func stream(instructions: String, history: [LocalTurn], prompt: String) -> AsyncThrowingStream<String, Error>
}

/// `LocalModel` over Foundation Models' `SystemLanguageModel.default`: a session of its own for
/// each request, made from the request's history, so concurrent requests never share one (a
/// session answers one request at a time) and nothing is kept between them.
public struct SystemLocalModel: LocalModel {
    public init() {}

    public func unavailability() async -> String? { OnDeviceModel.unavailability() }

    public func contextSize() async -> Int {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 0
    }

    public func tokenCount(instructions: String, history: [LocalTurn], prompt: String) async throws -> Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, macOS 26.4, *) {
            let entries = Self.transcript(instructions: instructions, history: history) + [
                .prompt(Transcript.Prompt(segments: [.text(.init(content: prompt))])),
            ]
            return try await SystemLanguageModel.default.tokenCount(for: entries)
        }
        #endif
        // Before 26.4 there is no counter: three characters a token is more than the model's
        // tokenizer takes for English, so what is kept fits.
        return (instructions.count + prompt.count + history.reduce(0) { $0 + $1.text.count }) / 3 + 8 * (history.count + 2)
    }

    public func stream(instructions: String, history: [LocalTurn], prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            guard #available(iOS 26, macOS 26, *) else {
                continuation.finish(throwing: LocalModelError.unavailable(OnDeviceModel.unavailability() ?? ""))
                return
            }
            let task = Task {
                let session = LanguageModelSession(transcript: Transcript(entries: Self.transcript(instructions: instructions, history: history)))
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.sorted(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            #else
            continuation.finish(throwing: LocalModelError.unavailable(OnDeviceModel.unavailability() ?? ""))
            #endif
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    static func transcript(instructions: String, history: [LocalTurn]) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: []))]
        for turn in history {
            let segments: [Transcript.Segment] = [.text(.init(content: turn.text))]
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        return entries
    }

    @available(iOS 26, macOS 26, *)
    static func sorted(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if #available(iOS 27, macOS 27, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return LocalModelError.tooLong
            case .guardrailViolation, .refusal:
                return LocalModelError.declined("Apple's on-device model wouldn't answer that.")
            case .unsupportedLanguageOrLocale:
                return LocalModelError.declined("Apple's on-device model doesn't speak that language yet.")
            default: return LocalModelError.failed(String(describing: error))
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return LocalModelError.tooLong
            case .guardrailViolation, .refusal:
                return LocalModelError.declined("Apple's on-device model wouldn't answer that.")
            case .unsupportedLanguageOrLocale:
                return LocalModelError.declined("Apple's on-device model doesn't speak that language yet.")
            case .assetsUnavailable:
                return LocalModelError.unavailable(OnDeviceModel.unavailability() ?? "Apple's on-device model isn't ready.")
            default: return LocalModelError.failed(String(describing: error))
            }
        }
        return LocalModelError.failed(String(describing: error))
    }
    #endif
}
