#if os(iOS) || os(macOS)
import AuthenticationServices
import Foundation

/// Opens the authorize URL in the system web-authentication sheet. The Claude flow redirects to a
/// loopback listener (or the hosted paste page), never to an app scheme, so the sheet is closed by
/// the caller once the code has arrived rather than by a callback URL.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ url: URL, onDismiss: @escaping @MainActor () -> Void) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in
            Task { @MainActor in onDismiss() }
        }
        session.prefersEphemeralWebBrowserSession = false
        #if os(iOS) || os(macOS)
        session.presentationContextProvider = self
        #endif
        self.session = session
        session.start()
    }

    func close() {
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
