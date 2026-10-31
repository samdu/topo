import Foundation
import TopoTools

/// Where `topo open-url` delivers: the one sign-in waiting for its browser, or nobody. A login
/// registers for its life and is the only thing a URL reaches, so no other guest process can put
/// a sheet on the phone.
@MainActor
final class LoginBrowser {
    static let shared = LoginBrowser()

    private var waiting: (id: UUID, deliver: @Sendable (URL) -> Void)?

    /// `deliver` hears the URLs offered until `close(id)`.
    func open(_ deliver: @escaping @Sendable (URL) -> Void) -> UUID {
        let id = UUID()
        waiting = (id, deliver)
        return id
    }

    func close(_ id: UUID) {
        if waiting?.id == id { waiting = nil }
    }

    /// Hands `url` to the sign-in waiting for it; false when none is.
    func offer(_ url: URL) -> Bool {
        guard let waiting else { return false }
        waiting.deliver(url)
        return true
    }
}

/// `topo open-url URL`: Claude Code's `BROWSER` during a sign-in (`GuestTools.browser`). The URL
/// opens in the sign-in's sheet, and only while a sign-in is waiting for one, and only on Claude's
/// own hosts over https: outside a sign-in it is refused, so the mind cannot open pages on the
/// phone through it.
struct OpenURLTool: Tool {
    var browser: @Sendable (URL) async -> Bool = { url in await LoginBrowser.shared.offer(url) }

    /// The hosts Claude Code's login sends its browser to.
    static let hosts: Set<String> = ["claude.com", "claude.ai", "platform.claude.com"]

    let name = "open-url"
    let summary = "Claude Code's browser during Topo's sign-in; refused at any other time"
    let usage = """
    topo open-url URL                   opens Claude's sign-in page in the sign-in's sheet

    Only while Topo is signing in, and only an https URL on claude.com or claude.ai.
    """

    static func accepts(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil else { return false }
        return true
    }

    func run(_ arguments: [String]) async -> ToolReply {
        guard arguments.count == 1, let url = URL(string: arguments[0]) else { return .usage(usage) }
        guard Self.accepts(url) else {
            return ToolReply(status: ToolReply.refused, text: "topo open-url: only Claude's sign-in pages open here\n")
        }
        guard await browser(url) else {
            return ToolReply(status: ToolReply.refused, text: "topo open-url: no sign-in is waiting for a browser\n")
        }
        return .ok("")
    }
}
