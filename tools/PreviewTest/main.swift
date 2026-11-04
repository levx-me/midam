// Finding a dev server's address in agent output. Run:
// swiftc Sources/Midam/ChatParse.swift Sources/Midam/PreviewDetector.swift tools/PreviewTest/main.swift -o /tmp/previewtest && /tmp/previewtest
import Foundation

func urls(_ s: String) -> [String] { PreviewDetector.urls(in: s).map(\.absoluteString) }
assert(urls("  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host") == ["http://localhost:5173/"])
assert(urls("ready - started server on 0.0.0.0:3000, url: http://0.0.0.0:3000.") == ["http://localhost:3000"])
assert(urls("Serving at http://127.0.0.1:8000/docs/index.html (Ctrl-C)") == ["http://127.0.0.1:8000/docs/index.html"])
assert(urls("listening on http://[::1]:4000") == ["http://[::1]:4000"])
assert(urls("\u{1b}[36mhttp://localhost:8080/\u{1b}[39m") == ["http://localhost:8080/"]) // colour codes
assert(urls("open 'http://localhost:3000/app'") == ["http://localhost:3000/app"])
assert(urls("https://example.com:3000 and http://localhost/ and localhost:3000").isEmpty) // not local, no port, no scheme

func tool(_ name: String, _ status: ChatItem.ToolStatus = .done) -> ChatItem {
    ChatItem(id: UUID().uuidString, kind: .tool(name: name, line: "", subject: nil, detail: "npm run dev\nLocal: http://localhost:5173/", status: status))
}
let user = ChatItem(id: "u", kind: .user(text: "hi", queued: false))
assert(PreviewDetector.urls(in: tool("Bash")).map(\.absoluteString) == ["http://localhost:5173/"])
assert(PreviewDetector.edited([user, tool("Read"), tool("Edit")]))
assert(!PreviewDetector.edited([tool("Write"), user, tool("Bash")]))   // an earlier turn's edit
assert(!PreviewDetector.edited([user, tool("Write", .failed)]))

assert(PreviewDetector.isLocal(URL(string: "http://localhost:5173/about")!))
assert(PreviewDetector.isLocal(URL(string: "about:blank")!))
assert(!PreviewDetector.isLocal(URL(string: "https://github.com/x")!))
print("preview: checks passed")

func nav(_ s: String, _ clicked: Bool) -> PreviewDetector.Navigation { PreviewDetector.navigation(to: URL(string: s)!, clicked: clicked) }
assert(nav("http://localhost:3000/a", false) == .stay)
assert(nav("http://localhost:3000/a", true) == .stay)
assert(nav("file:///Users/x/run.command", true) == .cancel)
assert(nav("file:///Users/x/run.command", false) == .cancel)
assert(nav("vscode://file/x", true) == .cancel)
assert(nav("x-apple.systempreferences:com.apple.preference", true) == .cancel)
assert(nav("https://example.com/", true) == .openExternally)
assert(nav("https://example.com/", false) == .cancel)
assert(nav("mailto:a@example.com", true) == .openExternally)
