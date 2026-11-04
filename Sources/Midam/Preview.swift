import AppKit
import SwiftUI
import WebKit

// The project's Preview tab: the app an agent's dev server serves, in a web view, at a desktop,
// tablet or phone width. No address bar (the people Midam is for never type one); the address is
// in the tab's tooltip. It stays on the dev server: other links open in the person's browser.

/// One project's preview: its address, the web view (made when first shown, so a restored tab
/// does not load until it is looked at), and whether the server answered.
@MainActor final class PreviewPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Width: String, CaseIterable { case desktop, tablet, phone }
    @Published private(set) var url: URL
    @Published var width = Width.desktop
    /// The server did not answer: the tab says so, with Reload.
    @Published private(set) var down = false
    private var web: WKWebView?

    init(url: URL) { self.url = url }

    var view: WKWebView {
        if let web { return web }
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.load(URLRequest(url: url))
        web = w
        return w
    }

    /// A new address for the project's preview (the agent started the server elsewhere).
    func go(_ to: URL) {
        guard to != url else { return reload() }
        url = to
        web?.load(URLRequest(url: to))
    }

    func reload() {
        down = false
        guard let web else { return } // not shown yet: it loads when it is
        if web.url == nil { web.load(URLRequest(url: url)) } else { web.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let to = action.request.url, action.targetFrame?.isMainFrame != false, !PreviewDetector.isLocal(to) else { return .allow }
        NSWorkspace.shared.open(to)
        return .cancel
    }

    // target="_blank": local pages open here, others in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let to = action.request.url else { return nil }
        if PreviewDetector.isLocal(to) { webView.load(URLRequest(url: to)) } else { NSWorkspace.shared.open(to) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { down = true }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { down = false }
}

struct PreviewView: View {
    @ObservedObject var page: PreviewPage
    let top: CGFloat
    let ground: Color

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat? = switch page.width { case .desktop: nil; case .tablet: 820; case .phone: 390 }
            WebHost(web: page.view)
                .frame(width: w.map { min($0, geo.size.width) })
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) { if w != nil { Divider() } }
                .overlay(alignment: .trailing) { if w != nil { Divider() } }
        }
        .padding(.top, top + 44) // under the header and the floating controls
        .background(ground)
        .overlay {
            if page.down {
                VStack(spacing: 8) {
                    Text("The preview isn't running").font(.headline)
                    Text("Ask the agent to start it, then reload.").foregroundStyle(.secondary)
                    Button("Reload") { page.reload() }.buttonStyle(.borderedProminent).padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ground)
                .padding(.top, top)
            }
        }
        .overlay(alignment: .top) { controls.padding(.top, top + 6) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    /// The only glass here: width presets and Reload, floating over the page's top.
    private var controls: some View {
        HStack(spacing: 6) {
            Picker("Page Width", selection: $page.width) {
                Label("Desktop", systemImage: "desktopcomputer").tag(PreviewPage.Width.desktop)
                Label("Tablet", systemImage: "ipad").tag(PreviewPage.Width.tablet)
                Label("Phone", systemImage: "iphone").tag(PreviewPage.Width.phone)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            Button { page.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload")
                .fastTip(Text("Reload"))
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .glassCapsule()
    }
}

private struct WebHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
