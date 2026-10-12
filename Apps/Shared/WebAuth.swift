#if os(iOS) || os(macOS)
import AuthenticationServices
import Foundation

/// Opens the authorize URL in the system web-authentication sheet. The Claude flow redirects to a
/// loopback listener (or the hosted paste page), never to an app scheme, so the sheet is closed by
/// the caller once the code has arrived rather than by a callback URL.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// A sheet: started once, and cancelled by the app when it closes or replaces it.
    protocol Sheet: AnyObject {
        func begin()
        func cancel()
    }

    private var session: Sheet?
    private var current: UUID?
    /// Makes the sheet for a URL, given what to call when it has gone. A test makes its own.
    var makeSheet: ((URL, @escaping @Sendable () -> Void) -> Sheet)?

    func open(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        close()
        // Only the sheet still open reports its dismissal: one closed or replaced by the caller
        // (the sign-in opening its second authorization) is not the person closing the browser.
        let id = UUID()
        // `@Sendable` so the completion is not main-actor-isolated by inference: the framework
        // owns the thread it calls back on, and Swift 6 traps an isolated closure off it.
        let gone: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.current == id else { return }
                self.session = nil
                self.current = nil
                onDismiss()
            }
        }
        let session = makeSheet?(url, gone) ?? system(url, gone)
        self.session = session
        current = id
        session.begin()
    }

    private func system(_ url: URL, _ gone: @escaping @Sendable () -> Void) -> Sheet {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable _, _ in gone() }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        return session
    }

    func close() {
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
    func begin() { start() }
}
#endif
