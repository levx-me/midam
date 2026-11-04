import Foundation
import JavaScriptCore

/// "N changes" for a document that is not open in a tab (its sidebar row): changes.js's midamDiff
/// run in JavaScriptCore with the page's own marked and markdown.js, so the row and the page never
/// disagree. One context, made on first use and reused, on its own queue.
enum ChangeCount {
    private static let queue = DispatchQueue(label: queueName, qos: .utility)
    private static let queueName = "dev.midam.change-count" // not a UI string
    /// Touched on `queue` only.
    nonisolated(unsafe) private static var shared: JSContext?

    /// The number of places changed from `old` to `new`; 0 if the scripts cannot run.
    static func count(old: String, new: String) async -> Int {
        await withCheckedContinuation { done in
            queue.async {
                if shared == nil, let dir = Bundle.main.resourceURL { shared = context(resources: dir) }
                done.resume(returning: shared.map { count(old: old, new: new, in: $0) } ?? 0)
            }
        }
    }

    /// A plain JSContext matches regexes without the JIT, which tries a ^-anchored one at every
    /// position of the text before it fails; marked runs its rules on the rest of the document for
    /// every block, so lexing grew quadratic (6 s for 5,000 lines). A sticky copy at index 0 is
    /// tried there only, with the same matches: about 60 ms. Not for the page, which has the JIT.
    static let anchored = """
    (() => {
      const exec = RegExp.prototype.exec, sticky = new WeakMap();
      RegExp.prototype.exec = function (s) {
        if (this.global || this.sticky || this.multiline || this.source[0] !== "^") return exec.call(this, s);
        let re = sticky.get(this);
        if (!re) sticky.set(this, re = new RegExp(this.source, this.flags + "y"));
        re.lastIndex = 0;
        return exec.call(re, s);
      };
    })();
    """

    /// A context running marked, markdown.js and changes.js from `resources`, or nil if one is
    /// missing or fails.
    static func context(resources: URL) -> JSContext? {
        guard let ctx = JSContext() else { return nil }
        ctx.evaluateScript(anchored)
        for name in ["marked.umd.js", "markdown.js", "changes.js"] {
            let url = resources.appendingPathComponent(name)
            guard let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            ctx.evaluateScript(script, withSourceURL: url)
        }
        return ctx.exception == nil ? ctx : nil
    }

    static func count(old: String, new: String, in ctx: JSContext) -> Int {
        ctx.exception = nil
        let count = ctx.objectForKeyedSubscript("midamDiff").call(withArguments: [old, new])?.forProperty("count")
        guard ctx.exception == nil, let count, count.isNumber else { return 0 }
        return Int(count.toInt32())
    }
}
