#if os(iOS) || os(macOS)
import AuthenticationServices
import Foundation

/// Opens the authorize URL in the system web-authentication sheet. The Claude flow redirects to a
/// loopback listener (or the hosted paste page), never to an app scheme, so the sheet is closed by
/// the caller once the code has arrived rather than by a callback URL.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var current: UUID?

    func open(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        close()
        // Only the sheet still open reports its dismissal: one closed or replaced by the caller
        // (the sign-in opening its second authorization) is not the person closing the browser.
        let id = UUID()
        // `@Sendable` so the completion is not main-actor-isolated by inference: the framework
        // owns the thread it calls back on, and Swift 6 traps an isolated closure off it.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.current == id else { return }
                self.session = nil
                self.current = nil
                onDismiss()
            }
        }
        session.prefersEphemeralWebBrowserSession = false
        #if os(iOS) || os(macOS)
        session.presentationContextProvider = self
        #endif
        self.session = session
        current = id
        session.start()
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
#endif
