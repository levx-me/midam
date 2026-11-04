import Foundation

/// One remark on a passage: the quote, its source line range (1-based, inclusive) and the text.
struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var quote: String
    /// The Markdown file the lines belong to, as given by the document (absolute).
    var path: String
    var start: Int
    var end: Int
    var text: String
    var created = Date()
}

enum Verdict: String, Codable {
    case approve, changes
}

/// The localised words the Markdown reply needs, filled by the caller from Localizable.strings so
/// this file stays pure. Title "Review" / "검토"; verdict names "Approve" / "승인", "Request changes" / "변경 요청".
struct ReplyWords: Equatable {
    var title: String
    var approve: String
    var changes: String
}

/// A document's draft reply: notes, an overall verdict and an optional summary.
struct Reply: Codable, Equatable {
    var notes: [Note] = []
    var verdict: Verdict?
    var summary = ""

    static let quoteLimit = 200

    /// `path` relative to `root` when it lies inside it, else just the file name.
    static func display(_ path: String, root: String?) -> String {
        if let root, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix), path.count > prefix.count { return String(path.dropFirst(prefix.count)) }
        }
        return (path as NSString).lastPathComponent
    }

    /// The Markdown reply (spec V6): heading with the verdict, the summary, then the notes in
    /// document order (start line, then creation time) as a numbered list of `path:L40-L52`, the
    /// quote as a blockquote, and the text.
    func markdown(path: String, root: String? = nil, words: ReplyWords) -> String {
        var head = "## \(Reply.display(path, root: root)) \(words.title)"
        if let verdict { head += ": " + (verdict == .approve ? words.approve : words.changes) }
        var out = [head]
        let summary = self.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { out.append(summary) }
        let ordered = notes.sorted { ($0.start, $0.created) < ($1.start, $1.created) }
        for (i, note) in ordered.enumerated() {
            let bullet = "\(i + 1). "
            let pad = String(repeating: " ", count: bullet.count)
            let range = note.start == note.end ? "L\(note.start)" : "L\(note.start)-L\(note.end)"
            var lines = ["\(bullet)`\(Reply.display(note.path, root: root)):\(range)`"]
            for l in Reply.trimmed(note.quote).split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(pad + (l.isEmpty ? ">" : "> " + l))
            }
            for l in note.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(l.isEmpty ? "" : pad + l)
            }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// The quote cut to about `quoteLimit` characters, with an ellipsis.
    private static func trimmed(_ quote: String) -> String {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count > quoteLimit else { return q }
        return String(q.prefix(quoteLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Drafts on disk, one JSON file per document under Application Support/Midam/Replies. Never
/// touches the document itself.
enum ReplyStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Midam/Replies", isDirectory: true)

    static func file(for path: String, in dir: URL = directory) -> URL {
        dir.appendingPathComponent(DocKey.hash(path) + ".json")
    }

    /// The saved draft, or an empty one when there is none or the file is corrupt.
    static func load(_ path: String, in dir: URL = directory) -> Reply {
        guard let data = try? Data(contentsOf: file(for: path, in: dir)),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return Reply() }
        return reply
    }

    /// Saves the draft atomically; an empty draft removes the file instead.
    static func save(_ reply: Reply, for path: String, in dir: URL = directory) throws {
        if reply == Reply() { return clear(path, in: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(reply).write(to: file(for: path, in: dir), options: .atomic)
    }

    static func clear(_ path: String, in dir: URL = directory) {
        try? FileManager.default.removeItem(at: file(for: path, in: dir))
    }
}
