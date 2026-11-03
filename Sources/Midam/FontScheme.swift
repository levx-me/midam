import Foundation
import WebKit

// midam-font:///<File>.woff2 serves the bundled fonts to the page (CSP: font-src midam-font:).
// WebKit renders in its own process, which the app's font registration does not reach, and
// the page may not read the bundle by file: URL for fonts. Only plain .woff2 file names directly
// inside Contents/Resources/Fonts are served; nothing else on disk is reachable through it.

/// The file name a midam-font URL asks for, or nil unless it is exactly `midam-font:///<name>`
/// with a plain `[A-Za-z0-9._-]+.woff2` name: no host, folders, "..", query or fragment.
func bundledFontFileName(_ url: URL) -> String? {
    guard url.scheme == FontSchemeHandler.scheme, url.host?.isEmpty ?? true,
          url.query == nil, url.fragment == nil, !url.hasDirectoryPath, url.path.hasPrefix("/") else { return nil }
    let name = String(url.path.dropFirst()) // percent-decoded, so %2F becomes a "/" and fails
    guard !name.contains(".."), name.range(of: "^[A-Za-z0-9._-]+\\.woff2$", options: .regularExpression) != nil
    else { return nil }
    return name
}

@MainActor final class FontSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "midam-font"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let name = bundledFontFileName(url),
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true).resolvingSymlinksInPath()
        else { return task.didFailWithError(URLError(.badURL)) }
        let file = dir.appendingPathComponent(name, isDirectory: false).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == dir.path, let data = try? Data(contentsOf: file)
        else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        // The page's origin is file:, so the font is a cross-origin load and needs CORS.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "font/woff2", "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
        ])
        task.didReceive(response ?? URLResponse(url: url, mimeType: "font/woff2", expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {} // answered synchronously in start
}
