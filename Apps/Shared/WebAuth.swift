#if os(iOS) || os(macOS)
import AuthenticationServices
import Foundation

/// Opens the authorize URL in the system web-authentication sheet. The Claude flow redirects to a
/// loopback listener (or the hosted paste page), never to an app scheme, so the sheet is closed by
/// the caller once the code has arrived rather than by a callback URL.
///
/// Only the person closing the sheet that is up is a dismissal. A sheet the caller closed or
/// replaced tells nobody, and neither does one the system would not present: on the phone it
/// presents none while the app is not active, which is where a sign-in carried off to Safari comes
/// back to, so a sheet asked for then is kept and shown when the app is active. A sheet refused
/// stays the caller's to close, on either platform.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// A sheet: begun once, which answers whether the system took it, and cancelled by the app
    /// when it closes or replaces it.
    protocol Sheet: AnyObject {
        func begin() -> Bool
        func cancel()
    }

    /// How a sheet went: closed by the person, or never presented.
    enum Ending: Sendable { case dismissed, refused }

    private var session: Sheet?
    private var current: UUID?
    /// A sheet asked for that the system would not present yet, shown at the next activation.
    private var waiting: (url: URL, onDismiss: @MainActor () -> Void)?
    /// Whether the sheet asked for has been tried again since the system refused it.
    private var retried = false
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    /// Makes the sheet for a URL, given what to call when it has gone. A test makes its own.
    var makeSheet: ((URL, @escaping @Sendable (Ending) -> Void) -> Sheet)?
    /// Whether the app is active, which is when the system presents a sheet. A test answers it.
    var isActive: () -> Bool = {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    override init() {
        super.init()
        #if os(iOS)
        let becameActive = UIApplication.didBecomeActiveNotification
        #else
        let becameActive = NSApplication.didBecomeActiveNotification
        #endif
        observer = NotificationCenter.default.addObserver(forName: becameActive, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.activated() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func open(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        close()
        retried = false
        guard isActive() else {
            waiting = (url, onDismiss)
            return
        }
        present(url, onDismiss: onDismiss)
    }

    /// The app is active: a sheet that was waiting for that is shown.
    func activated() {
        guard let waiting, isActive() else { return }
        self.waiting = nil
        present(waiting.url, onDismiss: waiting.onDismiss)
    }

    private func present(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        // Only the sheet still open reports its ending: one closed or replaced by the caller
        // (the sign-in opening its second authorization) is not the person closing the browser.
        let id = UUID()
        // `@Sendable` so the completion is not main-actor-isolated by inference: the framework
        // owns the thread it calls back on, and Swift 6 traps an isolated closure off it.
        let ended: @Sendable (Ending) -> Void = { [weak self] ending in
            Task { @MainActor [weak self] in
                guard let self, self.current == id else { return }
                self.session = nil
                self.current = nil
                switch ending {
                case .dismissed: onDismiss()
                case .refused: self.refused(url, onDismiss: onDismiss)
                }
            }
        }
        let session = makeSheet?(url, ended) ?? system(url, ended)
        self.session = session
        current = id
        if !session.begin() {
            self.session = nil
            current = nil
            refused(url, onDismiss: onDismiss)
        }
    }

    /// The system would not present the sheet: it waits for the app's next activation. Refused
    /// while the app says it is active, it is tried once more and then waits, since nothing says
    /// when a system that keeps refusing would stop. It is never the person's dismissal.
    private func refused(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        waiting = (url, onDismiss)
        guard isActive(), !retried else { return }
        retried = true
        Task { @MainActor [weak self] in self?.activated() }
    }

    private func system(_ url: URL, _ ended: @escaping @Sendable (Ending) -> Void) -> Sheet {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable _, error in
            ended(Self.ending(error))
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        return session
    }

    /// What a session's completion says of its sheet. There is no callback scheme, so it ends
    /// only by the person's close (`canceledLogin`) or by the system not presenting it, which is
    /// every other error.
    nonisolated static func ending(_ error: (any Error)?) -> Ending {
        guard let error else { return .dismissed }
        return (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? .dismissed : .refused
    }

    func close() {
        waiting = nil
        current = nil
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
            #elseif os(macOS)
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}

extension ASWebAuthenticationSession: WebAuth.Sheet {
    func begin() -> Bool { start() }
}
#endif
