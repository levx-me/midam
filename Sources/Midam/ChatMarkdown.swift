import Foundation

/// An agent reply split into the blocks the conversation view draws: headings, paragraphs, list
/// items, quotes, code and rules. Inline styling (bold, code, links) is left to AttributedString.
/// ponytail: a line-based reading of Markdown, enough for chat replies; nested lists keep only an
/// indent level, and a table shows as its source in a code block.
enum ChatBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "1." for an ordered item, nil for a bullet.
    case item(text: String, marker: String?, indent: Int)
    case quote(String)
    case code(String)
    case rule
}

enum ChatMarkdown {
    static func blocks(_ md: String) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var para: [String] = [], code: [String]? = nil, table: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !table.isEmpty { out.append(.code(table.joined(separator: "\n"))); table = [] }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") || line.hasPrefix("~~~") { out.append(.code(code!.joined(separator: "\n"))); code = nil }
                else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); code = []; continue }
            if line.hasPrefix("|") { if !para.isEmpty { flush() }; table.append(line); continue }
            if !table.isEmpty { flush() }
            if line.isEmpty { flush(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush(); out.append(.heading(level: m.1.count, text: String(m.2))); continue
            }
            if line.wholeMatch(of: /(-\s*){3,}|(\*\s*){3,}|(_\s*){3,}/) != nil { flush(); out.append(.rule); continue }
            if let m = raw.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let marker = m.2.first?.isNumber == true ? String(m.2) : nil
                out.append(.item(text: String(m.3), marker: marker, indent: m.1.count / 2)); continue
            }
            if let m = line.firstMatch(of: /^>\s?(.*)$/) {
                flush()
                if case .quote(let q) = out.last { out[out.count - 1] = .quote(q + "\n" + m.1) } else { out.append(.quote(String(m.1))) }
                continue
            }
            para.append(line)
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) } // still streaming in
        flush()
        return out
    }
}
