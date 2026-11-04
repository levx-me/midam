import Foundation

// When an agent starts a dev server its address shows up in a tool's output ("Local:
// http://localhost:5173/"): that is the project's preview. Pure, so tools/PreviewTest checks it.
enum PreviewDetector {
    // A local address with a port and an optional path; stops at spaces, quotes, brackets and
    // control characters (terminal colour codes wrap the address in dev servers' output).
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{2,5}(?:/[^\s'"<>()\[\]`\x00-\x1f]*)?"#,
        options: .caseInsensitive)

    /// The local addresses in `text`, in order, without trailing punctuation; 0.0.0.0 (every
    /// interface, which no browser should open) as localhost.
    static func urls(in text: String) -> [URL] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            var s = String(text[Range($0.range, in: text)!])
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            return URL(string: s.replacingOccurrences(of: "0.0.0.0", with: "localhost"))
        }
    }

    /// The addresses an item shows: a tool's command and output, or the agent's reply.
    static func urls(in item: ChatItem) -> [URL] {
        switch item.kind {
        case .tool(_, _, _, let detail, _): urls(in: detail)
        case .assistant(let markdown, _): urls(in: markdown)
        default: []
        }
    }

    /// The turn that just ended (the items after the person's last message) changed files: the
    /// preview reloads.
    static func edited(_ items: [ChatItem]) -> Bool {
        let start = items.lastIndex { if case .user = $0.kind { true } else { false } } ?? -1
        return items[(start + 1)...].contains {
            if case .tool(let name, _, _, _, .done) = $0.kind { ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name) } else { false }
        }
    }

    /// Whether the web view may go to `url` itself: the dev server's own pages; anything else
    /// opens in the person's browser.
    static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["about", "data", "blob"].contains(scheme) { return true }
        return ["http", "https", "ws", "wss"].contains(scheme)
            && ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    enum Navigation: Equatable { case stay, openExternally, cancel }

    /// What the preview does with a navigation: local pages stay in the tab; only a click on an
    /// http, https or mailto link goes to the system; everything else (file:, app schemes, script
    /// redirects) is dropped.
    static func navigation(to url: URL, clicked: Bool) -> Navigation {
        if isLocal(url) { return .stay }
        let scheme = url.scheme?.lowercased() ?? ""
        return clicked && ["http", "https", "mailto"].contains(scheme) ? .openExternally : .cancel
    }
}
