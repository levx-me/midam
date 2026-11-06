import Foundation

// The sidebar's library: which .md files agents wrote, grouped by project and kind.
// Foundation only, so tools/LibraryTest can compile it alone; LibraryModel drives it.

/// Fixed, language-neutral kind IDs; `allCases` is the display order.
enum DocKind: String, CaseIterable, Codable, Sendable { case design, plan, research, ops, guide, handoff, instructions, memory, notes, other }
/// One language version of a document; `lang` nil is the base `x.md`, "ko" is `x.ko.md`.
struct DocVariant: Codable, Hashable, Sendable { let lang: String?; let path: String }
struct LibraryDoc: Identifiable, Hashable, Sendable {
    let id: String              // base path (x.md, even if only x.ko.md exists on disk)
    var variants: [DocVariant]  // base first, then by lang
    var langLabel: String?      // "EN · KO" when variants.count > 1, else nil
    var title: String           // first "# heading", else file name
    var folder: String          // shortened folder path for line 2
    var modified: Date          // newest variant mtime
    var kind: DocKind
    var deleted: Bool
    var unread: Bool
}
struct KindGroup: Identifiable, Hashable, Sendable { var id: DocKind { kind }; let kind: DocKind; var docs: [LibraryDoc]; var unread: Int }
struct LibraryProject: Identifiable, Hashable, Sendable {
    let id: String              // project root path
    var name: String            // last path component
    var parent: String?         // parent folder name, only when another project has the same name
    var groups: [KindGroup]     // fixed DocKind order, empty kinds omitted
    var docCount: Int
    var unread: Int
    var lastModified: Date
}
struct FoundAgents: Codable, Hashable, Sendable { var claudeProjects: Int; var codexSessions: Int }

/// What a previous scan saw on disk, so a missing file can show as deleted in its place.
struct KnownDoc: Codable, Hashable, Sendable { var title: String; var modified: Date; var kind: DocKind }

/// Everything the user did that the library remembers (LibraryModel keeps it in UserDefaults).
struct LibraryState: Sendable {
    var opened: [String: Date] = [:]        // resolved path → last time a tab showed it
    var pinned: [String] = []               // pinned project ids, in the user's order
    var added: Set<String> = []             // the registry: project ids the user registered (LibraryModel.register)
    var overrides: [String: DocKind] = [:]  // doc id → kind the user chose
    var dismissed: Set<String> = []         // deleted doc ids the user cleared
    var known: [String: KnownDoc] = [:]     // doc id → last seen on disk
    var modelKinds: [String: String] = [:]  // modelKey → DocKind raw value, "" when the model had no answer
}

/// A .md file a source says an agent wrote, the project it belongs to, and the session that wrote it.
struct Hit: Hashable, Sendable { let path: String; let project: String; var session: WritingSession? = nil }

/// The agent session that wrote a document, for "Resume the session that wrote this".
struct WritingSession: Codable, Hashable, Sendable {
    let agent: Agent
    let id: String
    let cwd: String  // where the session ran: `claude --resume` looks sessions up by this folder

    /// Agent session ids are UUIDs; only this shape is ever put on a command line (a leading "-"
    /// would read as an option).
    static func isValidID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.first != "-"
            && id.utf8.allSatisfy { $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// `~/.claude/projects/<slug>/<id>.jsonl`; a subagent's `<slug>/<id>/subagents/agent-….jsonl`
    /// belongs to its parent session `<id>`.
    static func claude(transcript: String, cwd: String?) -> WritingSession? {
        let parts = transcript.split(separator: "/")
        guard let cwd, let file = parts.last, file.hasSuffix(".jsonl") else { return nil }
        let id = parts.count >= 3 && parts[parts.count - 2] == "subagents" ? String(parts[parts.count - 3]) : String(file.dropLast(6))
        return isValidID(id) ? WritingSession(agent: .claude, id: id, cwd: cwd) : nil
    }

    /// `~/.codex/sessions/…/rollout-<date>-<uuid>.jsonl`: the uuid is the session_meta id.
    static func codex(rollout: String, cwd: String) -> WritingSession? {
        let stem = ((rollout as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = String(stem.suffix(36))
        return stem.count > 36 && UUID(uuidString: id) != nil ? WritingSession(agent: .codex, id: id, cwd: cwd) : nil
    }
}

/// A document as scanned, before the user's state (overrides, opens, dismissals) is applied.
struct DocInfo: Codable, Hashable, Sendable {
    let id: String
    let project: String
    let variants: [DocVariant]
    let modified: Date
    let title: String
    let folder: String
    let fixedKind: DocKind?     // frontmatter or location (steps 2–3): the model is not asked
    let ruleKind: DocKind       // file name, folder and heading words (steps 5–7)
    let modelKey: String?       // "path|mtime" for the Foundation Models cache; nil when fixedKind decides
    var excerpt: String         // for the model only; never written to the cache
    let deleted: Bool
    var session: WritingSession? = nil // the newest that wrote it; absent in caches from before (the rescan fills it)
    var sessions: [WritingSession]? = nil // every session that wrote it, newest first; absent in older caches
}

/// Where and when to scan; tests pass their own home, exclusions and clock.
struct ScanEnv: Sendable {
    var home: String
    /// Entries starting with "/" are path prefixes; anything else excludes paths containing it.
    var excluded: [String]
    var now: Date

    static func standard(now: Date = Date()) -> ScanEnv {
        ScanEnv(home: NSHomeDirectory(), excluded: Library.defaultExcluded(), now: now)
    }
}

/// The head of a document: frontmatter `kind:`, first `# ` title, later headings, opening text.
struct DocHead: Hashable, Sendable {
    var title: String?
    var kind: DocKind?
    var headings: [String] = []
    var excerpt = ""
}

enum Library {
    static func defaultExcluded(tmp: String = NSTemporaryDirectory()) -> [String] {
        var list = ["/tmp/", "/private/tmp/", "scratchpad"]
        let t = tmp.hasSuffix("/") ? tmp : tmp + "/"
        list.append(t)
        list.append(t.hasPrefix("/private/") ? String(t.dropFirst("/private".count)) : "/private" + t)
        return list
    }

    // MARK: Language pairs

    /// `dir/x.ko.md` → (`dir/x.md`, "ko"); `dir/x.md` → (`dir/x.md`, nil).
    static func split(_ path: String) -> (id: String, lang: String?) {
        let name = (path as NSString).lastPathComponent
        let stem = String(name.dropLast(3))     // callers only pass *.md
        guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else { return (path, nil) }
        let tag = String(stem[stem.index(after: dot)...])
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        let lang = String(parts[0])
        guard (2...3).contains(lang.count), lang.allSatisfy({ $0.isASCII && $0.isLowercase }),
              Locale.LanguageCode(lang).isISOLanguage,
              parts.count == 1 || (parts.count == 2 && parts[1].count == 2 && parts[1].allSatisfy({ $0.isASCII && $0.isUppercase }))
        else { return (path, nil) }
        let dir = (path as NSString).deletingLastPathComponent
        return ((dir as NSString).appendingPathComponent(String(stem[..<dot]) + ".md"), tag)
    }

    static func langLabel(_ variants: [DocVariant]) -> String? {
        variants.count > 1 ? variants.map { $0.lang?.uppercased() ?? "EN" }.joined(separator: " · ") : nil
    }

    // MARK: Head

    static func parseHead(_ text: String) -> DocHead {
        var head = DocHead()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        var i = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            i = 1
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
                if l == "---" || l == "..." { break }
                if l.hasPrefix("kind:") {
                    let v = l.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                    head.kind = DocKind(rawValue: v.lowercased())
                }
            }
        }
        var fence: String?
        for line in lines[min(i, lines.count)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = fence { if t.hasPrefix(f) { fence = nil }; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
            if t.hasPrefix("#") {
                let level = t.prefix { $0 == "#" }.count
                let rest = t.dropFirst(level)
                guard level <= 6, rest.isEmpty || rest.first == " " else { continue }
                let text = rest.trimmingCharacters(in: .whitespaces)
                if level == 1, head.title == nil, line.hasPrefix("# "), !text.isEmpty { head.title = text }
                else if head.headings.count < 8, !text.isEmpty { head.headings.append(text) }
                continue
            }
            if head.excerpt.count < 500, !t.isEmpty { head.excerpt += (head.excerpt.isEmpty ? "" : " ") + t }
        }
        return head
    }

    // MARK: Kinds

    /// Step 3: memory and hidden-folder notes are placement rules, decided by where the file is.
    static func locationKind(_ path: String, home: String) -> DocKind? {
        let claude = home + "/.claude/"
        if path.hasPrefix(claude) {
            let rel = path.dropFirst(claude.count).split(separator: "/")
            if rel.count == 4, rel[0] == "projects", rel[2] == "memory" { return .memory }
            return .notes
        }
        let dirs = (path as NSString).deletingLastPathComponent.split(separator: "/")
        return dirs.contains { $0.hasPrefix(".") } ? .notes : nil
    }

    /// File-name words, language-neutral. ADR → design: an ADR records a design decision, not a schedule.
    static let nameWords: [String: DocKind] = {
        var m: [String: DocKind] = [:]
        let table: [(DocKind, [String])] = [
            (.design, ["PRD", "SPEC", "SPECS", "SPECIFICATION", "DESIGN", "RFC", "ADR", "ARCHITECTURE", "REQUIREMENTS", "PROPOSAL"]),
            (.plan, ["PLAN", "PLANS", "ROADMAP", "TODO", "TODOS", "BACKLOG", "MILESTONES"]),
            (.research, ["RESEARCH", "REPORT", "REPORTS", "SURVEY", "ANALYSIS", "BENCHMARK", "BENCHMARKS", "FINDINGS"]),
            (.ops, ["DEPLOY", "DEPLOYMENT", "DEPLOYING", "RUNBOOK", "OPS", "INCIDENT", "RELEASE", "RELEASING", "POSTMORTEM", "ONCALL"]),
            (.guide, ["README", "GUIDE", "HOWTO", "TUTORIAL", "ENCYCLOPEDIA", "GLOSSARY", "WIKI", "MANUAL", "FAQ", "CONTRIBUTING"]),
            (.handoff, ["HANDOFF", "HANDOVER"]),
            (.instructions, ["CLAUDE", "AGENTS", "AGENT", "SKILL", "GEMINI", "COPILOT", "CURSORRULES", "WINDSURFRULES", "INSTRUCTIONS"]),
            (.memory, ["MEMORY"]),
        ]
        for (k, ws) in table { for w in ws { m[w] = k } }
        return m
    }()

    static let folderWords: [String: DocKind] = [
        "research": .research, "report": .research, "reports": .research,
        "skills": .instructions, "plans": .plan,
        "adr": .design, "adrs": .design, "decisions": .design, "rfc": .design, "rfcs": .design, "specs": .design,
        "runbooks": .ops, "guides": .guide, "handoffs": .handoff,
    ]

    /// Heading words per language, scored over the title and first headings. ASCII words match whole
    /// words; other scripts match as substrings (Korean particles attach to the word). Add a language
    /// by adding a key.
    static let headingWords: [String: [DocKind: [String]]] = [
        "en": [
            .design: ["spec", "specification", "design", "architecture", "prd", "rfc", "proposal", "requirements"],
            .plan: ["plan", "roadmap", "todo", "milestones", "phases", "schedule", "backlog"],
            .research: ["research", "report", "survey", "analysis", "findings", "benchmark", "comparison", "investigation", "study", "evaluation"],
            .ops: ["deploy", "deployment", "runbook", "incident", "release", "operations", "rollback", "outage", "postmortem"],
            .guide: ["guide", "how to", "tutorial", "readme", "getting started", "usage", "installation", "quick start", "manual", "glossary"],
            .handoff: ["handoff", "handover"],
            .instructions: ["instructions", "rules", "prompt", "skill", "playbook"],
            .memory: ["memory"],
            .notes: ["notes", "log", "journal", "scratch"],
        ],
        "ko": [
            .design: ["설계", "기획", "명세", "스펙", "요구 사항", "요구사항", "아키텍처"],
            .plan: ["계획", "일정", "로드맵", "할 일"],
            .research: ["조사", "리포트", "보고서", "분석", "비교", "연구", "벤치마크"],
            .ops: ["배포", "운영", "장애", "릴리스", "출시", "롤백"],
            .guide: ["안내", "가이드", "사용법", "설명서", "시작하기", "설치", "백과"],
            .handoff: ["인계", "인수인계"],
            .instructions: ["지시", "규칙", "지침"],
            .memory: ["메모리"],
            .notes: ["노트", "메모", "일지"],
        ],
    ]

    /// Upper-cased words of a file name: `v1-spec` → [V1, SPEC], `deployGuide` → [DEPLOY, GUIDE].
    static func nameTokens(_ stem: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var prevLower = false
        for c in stem {
            if !(c.isLetter || c.isNumber) { if !cur.isEmpty { tokens.append(cur) }; cur = ""; prevLower = false; continue }
            if c.isUppercase && prevLower { tokens.append(cur); cur = "" }
            cur.append(c)
            prevLower = c.isLowercase
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens.map { $0.uppercased() }
    }

    /// Steps 5–7. `relDir` is the folder relative to the project root (or the absolute folder).
    static func ruleKind(stem: String, relDir: String, title: String, headings: [String]) -> DocKind {
        // The last matching word wins: English compounds put the head noun last ("deploy-plan" is a plan).
        if let k = nameTokens(stem).reversed().lazy.compactMap({ nameWords[$0] }).first { return k }
        if let k = relDir.split(separator: "/").reversed().lazy.compactMap({ folderWords[$0.lowercased()] }).first { return k }
        var score: [DocKind: Int] = [:]
        let texts = [(title, 3)] + headings.map { ($0, 1) }
        for (text, weight) in texts {
            let lower = text.lowercased()
            let words = " " + lower.split { !($0.isLetter || $0.isNumber) }.joined(separator: " ") + " "
            for table in headingWords.values {
                for (kind, list) in table where list.contains(where: { w in
                    w.allSatisfy(\.isASCII) ? words.contains(" \(w) ") : lower.contains(w)
                }) { score[kind, default: 0] += weight }
            }
        }
        var best = DocKind.other
        var top = 0
        for k in DocKind.allCases { if let s = score[k], s > top { best = k; top = s } }
        return best
    }

    /// Final kind: user override → fixed (frontmatter/location) → model → rules.
    static func kind(_ info: DocInfo, state: LibraryState) -> DocKind {
        state.overrides[info.id] ?? info.fixedKind
            ?? info.modelKey.flatMap { state.modelKinds[$0] }.flatMap(DocKind.init(rawValue:))
            ?? info.ruleKind
    }

    /// Docs that reached the model step and have no cached answer yet.
    static func pendingModel(_ infos: [DocInfo], state: LibraryState) -> [DocInfo] {
        infos.filter { i in
            guard !i.deleted, i.fixedKind == nil, state.overrides[i.id] == nil, let key = i.modelKey else { return false }
            return state.modelKinds[key] == nil
        }
    }

    // MARK: Folder line (D8)

    static func folderLine(dir: String, root: String, home: String) -> String {
        var comps: [String]
        if dir == root || dir.hasPrefix(root + "/") {
            comps = dir.dropFirst(root.count).split(separator: "/").map(String.init)
            if comps.first == "docs" { comps.removeFirst() }
        } else if dir == home || dir.hasPrefix(home + "/") {
            comps = ["~"] + dir.dropFirst(home.count).split(separator: "/").map(String.init)
        } else {
            comps = [""] + dir.split(separator: "/").map(String.init)
        }
        if comps.count > 3 { comps = [comps[0], "…", comps[comps.count - 1]] }
        return comps.joined(separator: "/")
    }

    // MARK: Unread, grouping, order

    static func lastOpen(_ variants: [DocVariant], opened: [String: Date]) -> Date? {
        variants.compactMap { opened[$0.path] }.max()
    }

    /// D5: never opened in Midam, or changed after the latest open of any variant.
    static func unread(_ variants: [DocVariant], modified: Date, opened: [String: Date]) -> Bool {
        guard let last = lastOpen(variants, opened: opened) else { return true }
        return modified > last
    }

    /// First run (nothing saved yet): everything found counts as read, as of its current change.
    static func baseline(_ infos: [DocInfo]) -> [String: Date] {
        var seen: [String: Date] = [:]
        for i in infos where !i.deleted { for v in i.variants { seen[v.path] = i.modified } }
        return seen
    }

    static func projects(_ infos: [DocInfo], state: LibraryState) -> [LibraryProject] {
        var byProject: [String: [LibraryDoc]] = [:]
        var lastRead: [String: Date] = [:]
        for i in infos {
            if i.deleted && state.dismissed.contains(i.id) { continue }
            let doc = LibraryDoc(id: i.id, variants: i.variants, langLabel: langLabel(i.variants), title: i.title,
                                 folder: i.folder, modified: i.modified, kind: kind(i, state: state), deleted: i.deleted,
                                 unread: !i.deleted && unread(i.variants, modified: i.modified, opened: state.opened))
            byProject[i.project, default: []].append(doc)
            if let t = lastOpen(i.variants, opened: state.opened) { lastRead[i.project] = max(t, lastRead[i.project] ?? t) }
        }
        var list = byProject.map { root, docs in
            let groups = DocKind.allCases.compactMap { k -> KindGroup? in
                let ds = docs.filter { $0.kind == k }.sorted { $0.modified > $1.modified }
                return ds.isEmpty ? nil : KindGroup(kind: k, docs: ds, unread: ds.filter(\.unread).count)
            }
            return LibraryProject(id: root, name: (root as NSString).lastPathComponent, parent: nil, groups: groups,
                                  docCount: docs.count, unread: docs.filter(\.unread).count,
                                  lastModified: docs.map(\.modified).max() ?? .distantPast)
        }
        let names = Dictionary(grouping: list, by: \.name)
        for n in list.indices where names[list[n].name]!.count > 1 {
            list[n].parent = ((list[n].id as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        return order(list, lastRead: lastRead)
    }

    /// All Projects: last read in Midam first, then never-read projects by last change.
    static func order(_ list: [LibraryProject], lastRead: [String: Date]) -> [LibraryProject] {
        let byChange = list.sorted { $0.lastModified != $1.lastModified ? $0.lastModified > $1.lastModified : $0.id < $1.id }
        let read = byChange.filter { lastRead[$0.id] != nil }.sorted { lastRead[$0.id]! > lastRead[$1.id]! }
        return read + byChange.filter { lastRead[$0.id] == nil }
    }

    /// What to remember for deleted-doc detection after a full scan (dismissed deleted docs are forgotten).
    static func known(_ infos: [DocInfo], state: LibraryState) -> [String: KnownDoc] {
        var out: [String: KnownDoc] = [:]
        for i in infos where !(i.deleted && state.dismissed.contains(i.id)) {
            out[i.id] = KnownDoc(title: i.title, modified: i.modified, kind: kind(i, state: state))
        }
        return out
    }
}

// MARK: Sections, pins and filters

extension Library {
    /// The sidebar's two sections: pinned projects in the user's order (ids not listed now are
    /// skipped), then All Projects as listed, without the pinned ones.
    static func sections(_ list: [LibraryProject], pinned: [String]) -> (pinned: [LibraryProject], all: [LibraryProject]) {
        let byId = Dictionary(list.map { ($0.id, $0) }) { a, _ in a }
        let set = Set(pinned)
        return (pinned.compactMap { byId[$0] }, list.filter { !set.contains($0.id) })
    }

    /// `id` pinned where the drop indicator showed it. Without a target (the ⋯ menu, the section
    /// header, the empty drop zone) it goes to the bottom. A pinned project dropped on another
    /// lands after it when it came from above and before it from below; a new pin lands before it.
    static func pin(_ id: String, onto target: String? = nil, in pinned: [String]) -> [String] {
        guard let target, target != id, let to = pinned.firstIndex(of: target) else { return pinned.contains(id) ? pinned : pinned + [id] }
        var ids = pinned
        if let from = ids.firstIndex(of: id) { ids.remove(at: from) }
        ids.insert(id, at: to) // after a removal above it, `to` is just past the target
        return ids
    }

    /// The documents `session` wrote, newest first (a session's id is unique across agents).
    static func docs(ofSession id: String, in infos: [DocInfo]) -> [DocInfo] {
        infos.filter { i in !i.deleted && (i.sessions ?? i.session.map { [$0] } ?? []).contains { $0.id == id } }
            .sorted { $0.modified > $1.modified }
    }

    static func movePinned(_ id: String, by d: Int, in pinned: [String], listed: Set<String>) -> [String] {
        guard let i = pinned.firstIndex(of: id) else { return pinned }
        var j = i + d
        while pinned.indices.contains(j), !listed.contains(pinned[j]) { j += d }
        guard pinned.indices.contains(j) else { return pinned }
        var ids = pinned
        ids.swapAt(i, j)
        return ids
    }

    /// Only the documents `keep` takes; groups and projects left empty go, and the unread
    /// counts are those of what is left.
    static func filter(_ list: [LibraryProject], keep: (LibraryDoc) -> Bool) -> [LibraryProject] {
        list.compactMap { p in
            var p = p
            p.groups = p.groups.compactMap { g in
                var g = g
                g.docs = g.docs.filter(keep)
                g.unread = g.docs.filter(\.unread).count
                return g.docs.isEmpty ? nil : g
            }
            p.docCount = p.groups.reduce(0) { $0 + $1.docs.count }
            p.unread = p.groups.reduce(0) { $0 + $1.unread }
            return p.groups.isEmpty ? nil : p
        }
    }

    static func unreadIds(_ list: [LibraryProject]) -> Set<String> {
        Set(list.flatMap { $0.groups.flatMap { $0.docs.filter(\.unread).map(\.id) } })
    }

    /// The unread filter: what was unread when it was turned on (`kept`) stays, read since or
    /// not, and anything unread now joins it. Turning it off and on again takes a fresh `kept`.
    static func unreadFilter(_ list: [LibraryProject], kept: Set<String>) -> [LibraryProject] {
        filter(list) { kept.contains($0.id) || $0.unread }
    }

    /// Project ids and kind keys (as SidebarState keys them) of a tree, for auto-expanding it.
    static func groupKeys(_ list: [LibraryProject], sep: String = "\u{1F}") -> Set<String> {
        Set(list.flatMap { p in [p.id] + p.groups.map { p.id + sep + $0.kind.rawValue } })
    }
}

// MARK: Search

/// How a document matched a sidebar search: in its title, its file name, or only in its text
/// (then `snippet` is the matching line, cut to a short window around the match).
struct DocMatch: Hashable, Sendable {
    var title = false
    var name = false
    var snippet: String?
}

extension Library {
    /// The query's search terms: words split on whitespace, a "quoted phrase" kept whole.
    static func terms(_ query: String) -> [String] {
        query.components(separatedBy: "\"").enumerated().flatMap { i, part in
            i % 2 == 1 ? [part.trimmingCharacters(in: .whitespacesAndNewlines)] : part.split(whereSeparator: \.isWhitespace).map(String.init)
        }.filter { !$0.isEmpty }
    }

    /// Where `term` occurs in `text`, ignoring case and diacritics.
    static func hits(_ term: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// Where any of the query's terms occurs in `text`, in order; empty for an empty query.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        terms(query).flatMap { hits($0, in: text) }.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Every term must occur somewhere: the title, the file name or the text (read only for the
    /// terms neither name holds, which then give the snippet).
    static func match(_ query: String, title: String, name: String, text: () -> String?) -> DocMatch? {
        let ts = terms(query)
        guard !ts.isEmpty else { return nil }
        let has = { (t: String, s: String) in !hits(t, in: s).isEmpty }
        var m = DocMatch(title: ts.contains { has($0, title) }, name: ts.contains { has($0, name) })
        let rest = ts.filter { !has($0, title) && !has($0, name) }
        if rest.isEmpty { return m }
        guard let t = text(), rest.allSatisfy({ has($0, t) }), let s = snippet(rest[0], term: true, in: t) else { return nil }
        m.snippet = s
        return m
    }

    /// The line holding the first match, its Markdown markers trimmed, cut to about `width`
    /// characters with the match in view ("…" where it was cut). `term`: `query` is one term.
    static func snippet(_ query: String, term: Bool = false, in text: String, width: Int = 80) -> String? {
        let t = term ? query : (terms(query).first ?? "")
        guard !t.isEmpty, let r = hits(t, in: text).first else { return nil }
        let lineRange = text.lineRange(for: r)
        var line = Substring(text[lineRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = CharacterSet(charactersIn: "#>-*+|` \t")
        while let c = line.unicodeScalars.first, markers.contains(c), line.count > 1 { line.removeFirst() }
        guard let at = line.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) else { return line }
        let before = line.distance(from: line.startIndex, to: at.lowerBound)
        let lead = max(0, min(before - 24, line.count - width)) // ~24 characters of context before the match
        var out = String(line.dropFirst(lead).prefix(width))
        if lead > 0 { out = "…" + out }
        if lead + width < line.count { out += "…" }
        return out
    }
}

/// The documents' text for the sidebar search, read off the main thread and kept per path and
/// modification time.
// ponytail: every listed doc's text stays in memory (~600 docs, a few MB); an LRU if libraries grow.
actor DocTexts {
    private var cache: [String: (mtime: Date, text: String)] = [:]

    func text(_ path: String) -> String? {
        guard let m = LibraryScanner.mtime(path) else { return nil }
        if let c = cache[path], c.mtime == m { return c.text }
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4_000_000 else { return nil }
        let t = String(decoding: data, as: UTF8.self)
        cache[path] = (m, t)
        return t
    }

    /// Each matching document by id. Stops early when the calling task is cancelled.
    func search(_ query: String, in docs: [LibraryDoc]) -> [String: DocMatch] {
        var out: [String: DocMatch] = [:]
        for d in docs {
            if Task.isCancelled { break }
            let match = Library.match(query, title: d.title, name: (d.id as NSString).lastPathComponent) {
                d.deleted ? nil : d.variants.compactMap { text($0.path) }.joined(separator: "\n")
            }
            if let match { out[d.id] = match }
        }
        return out
    }

    /// Reads ahead while the user types the first letters.
    func warm(_ paths: [String]) { for p in paths { if Task.isCancelled { return }; _ = text(p) } }
}

// MARK: Cache

/// A .md write found in a transcript, with the cwd of its own line (nil: the file's first cwd applies).
struct Found: Codable, Hashable, Sendable { let path: String; let cwd: String? }

/// How far a scan read a Claude transcript (append-only JSONL): the next scan reads only from
/// `offset` (the end of its last complete line) when the file grew.
struct TranscriptMark: Codable, Hashable, Sendable {
    var size: Int
    var mtime: Date
    var offset: Int
    var cwd: String?     // the first "cwd" in the bytes before `offset`
    var found: [Found]   // the writes in those bytes
}

/// A Codex session as last read: its cwd and run time; unchanged size and mtime skip the read.
struct CodexRun: Codable, Hashable, Sendable { let cwd: String; let start: Date; let end: Date }
struct SessionMark: Codable, Hashable, Sendable { var size: Int; var mtime: Date; var run: CodexRun? }

/// Per-source read state carried from one scan to the next (keyed by path).
struct ScanMarks: Codable, Hashable, Sendable {
    var transcripts: [String: TranscriptMark] = [:]
    var sessions: [String: SessionMark] = [:]
}

/// The last completed scan, in Application Support/Midam/library.plist (binary): shown at launch
/// before the rescan, which reads only what changed since (`marks`). Another version is ignored.
struct LibraryCache: Codable, Sendable {
    /// Bump when the scan's rules change: a cache from other rules is ignored, not shown stale.
    static let currentVersion = 2
    var version = currentVersion
    var infos: [DocInfo]
    var agents: FoundAgents
    var marks: ScanMarks

    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Midam/library.plist")
    }

    /// nil when missing, unreadable, corrupt or of another version.
    static func read(_ url: URL = standardURL) -> LibraryCache? {
        guard let data = try? Data(contentsOf: url),
              let c = try? PropertyListDecoder().decode(LibraryCache.self, from: data),
              c.version == currentVersion else { return nil }
        return c
    }

    func write(_ url: URL = Self.standardURL) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        var stored = self
        stored.infos = infos.map { var i = $0; i.excerpt = ""; return i } // no document text on disk
        guard let data = try? enc.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The agent CLIs Midam knows. It reads the history of claude and codex; another history source
/// adds its reader in LibraryScanner and its entry in `LibraryScanner.candidates`. Cursor leaves
/// no history Midam reads: it is here for the agent terminal tabs (AgentSessions.swift).
enum Agent: String, CaseIterable, Codable, Sendable { case claude, codex, cursor }

/// A project found in an agent's history (any age), for the Add Project sheet.
struct ProjectCandidate: Identifiable, Hashable, Sendable {
    var id: String { agent.rawValue + ":" + root }
    let agent: Agent
    let root: String
    var lastSession: Date
    var sources: [String] // its transcripts or sessions, newest first
}

/// Reads transcripts into hits, and hits into documents. One per scan; it caches repo
/// roots and file heads, so it is not shared between threads.
final class LibraryScanner {
    let env: ScanEnv
    private var roots: [String: String?] = [:]
    private var heads: [String: (mtime: Date, head: DocHead)] = [:]
    private let fm = FileManager.default
    private var claudeDir: String { env.home + "/.claude" }

    /// The last scan's read state, given before scanning; `marks` is this scan's, for the next.
    var previous = ScanMarks()
    private(set) var marks = ScanMarks()

    init(env: ScanEnv) { self.env = env }

    func isExcluded(_ path: String) -> Bool {
        env.excluded.contains { $0.hasPrefix("/") ? path.hasPrefix($0) : path.contains($0) }
    }

    static func mtime(_ path: String) -> Date? { stamp(path)?.mtime }

    static func stamp(_ path: String) -> (size: Int, mtime: Date)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return (Int(st.st_size), Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9))
    }

    // MARK: Sources

    /// `~/.claude/projects/*/*.jsonl` and their subagents' `*/*/subagents/*.jsonl` of the registered
    /// projects, any age, newest first.
    func claudeTranscripts(registered: Set<String>) -> [String] {
        var out: [(String, Date)] = []
        for dir in claudeSlugs() {
            let all = claudeFiles(dir)
            if slugRoot(all).map(registered.contains) == true { out += all }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func claudeSlugs() -> [String] {
        let base = claudeDir + "/projects"
        return ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { !$0.hasPrefix(".") }.map { base + "/" + $0 }
    }

    /// One project folder's transcripts with their modification times, newest first.
    private func claudeFiles(_ dir: String) -> [(String, Date)] {
        var out: [(String, Date)] = []
        func add(_ dir: String) {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                if let m = Self.mtime(p) { out.append((p, m)) }
            }
        }
        add(dir)
        for session in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !session.hasSuffix(".jsonl") && session != "memory" {
            add(dir + "/" + session + "/subagents")
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// The project a Claude project folder is about now: the repo root of its newest session's latest
    /// cwd. Claude keeps a session in the folder it started in, so a repo that moved since (or a
    /// session that `cd`'d) is found where it is now, like RecentSessions.
    private func slugRoot(_ files: [(String, Date)]) -> String? {
        for (path, _) in files.prefix(3) {
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            let cwd = data.withUnsafeBytes { buf in buf.baseAddress.flatMap { Self.lastCwd($0, buf.count, skipping: claudeDir + "/") } }
            if let cwd { return sessionRoot(cwd) }
        }
        return nil
    }

    /// The last `"cwd":"…"` value not under `prefix` (subagents run from ~/.claude/projects/…).
    private static func lastCwd(_ base: UnsafeRawPointer, _ n: Int, skipping prefix: String) -> String? {
        var at = 0, last: String?
        while at < n, let i = find("\"cwd\":\"", base + at, n - at) {
            if let c = firstCwd(base + at + i, n - at - i), !c.hasPrefix(prefix) { last = c }
            at += i + 7
        }
        return last
    }

    private func sessionRoot(_ cwd: String) -> String? {
        let cwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard cwd != env.home, cwd != "/", !isExcluded(cwd + "/") else { return nil }
        return repoRoot(cwd) ?? cwd
    }

    func claudeProjectCount() -> Int {
        ((try? fm.contentsOfDirectory(atPath: claudeDir + "/projects")) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    /// `~/.codex/sessions/**/*.jsonl` whose cwd is in a registered project, any age, newest first.
    func codexSessions(registered: Set<String>) -> [String] {
        codexFiles().filter { p, _ in codexSession(p).flatMap { sessionRoot($0.cwd) }.map(registered.contains) == true }.map(\.0)
    }

    private func codexFiles() -> [(String, Date)] {
        let base = env.home + "/.codex/sessions"
        var out: [(String, Date)] = []
        for rel in fm.enumerator(atPath: base)?.compactMap({ $0 as? String }) ?? [] where rel.hasSuffix(".jsonl") {
            let p = base + "/" + rel
            if let m = Self.mtime(p) { out.append((p, m)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Every project in every agent's history, whatever its age, newest session first; one
    /// candidate per agent and project.
    func candidates() -> [ProjectCandidate] {
        var out: [String: ProjectCandidate] = [:]
        func add(_ agent: Agent, _ root: String, _ files: [(String, Date)]) {
            guard let newest = files.first else { return }
            let key = agent.rawValue + ":" + root
            if var c = out[key] {
                c.lastSession = max(c.lastSession, newest.1)
                c.sources += files.map(\.0)
                out[key] = c
            } else {
                out[key] = ProjectCandidate(agent: agent, root: root, lastSession: newest.1, sources: files.map(\.0))
            }
        }
        for dir in claudeSlugs() {
            let files = claudeFiles(dir)
            if let root = slugRoot(files) { add(.claude, root, files) }
        }
        for (p, m) in codexFiles() {
            if let root = codexSession(p).flatMap({ sessionRoot($0.cwd) }) { add(.codex, root, [(p, m)]) }
        }
        return out.values.sorted { $0.lastSession > $1.lastSession }
    }

    /// How many documents of the candidate's project its history holds (still on disk; language
    /// versions count once).
    func docCount(_ c: ProjectCandidate) -> Int {
        let hits = c.sources.flatMap { c.agent == .claude ? claudeHits($0) : codexHits($0) }
        return Set(hits.filter { $0.project == c.root && Self.mtime($0.path) != nil }.map { Library.split($0.path).id }).count
    }

    /// Write/Edit/MultiEdit of a .md in a Claude transcript. Only lines holding both `.md"` and
    /// `"tool_use"` are parsed; broken lines are skipped. A file that only grew since `previous`
    /// is read from where that scan stopped; one that shrank or changed in place, in full.
    func claudeHits(_ transcript: String) -> [Hit] {
        guard let st = Self.stamp(transcript) else { return [] }
        let old = (marks.transcripts[transcript] ?? previous.transcripts[transcript]).flatMap { m in
            (st.size == m.size && st.mtime == m.mtime) || st.size > m.size ? m : nil
        }
        var mark = old ?? TranscriptMark(size: 0, mtime: st.mtime, offset: 0, cwd: nil, found: [])
        guard let data = Self.read(transcript, from: mark.offset) else { return [] }
        var tail: [Found] = [], tailCwd: String?
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            // Through the last newline is kept in the mark; a line still being written is read again next time.
            let cut = (data.lastIndex(of: 10).map { $0 - data.startIndex + 1 }) ?? 0
            mark.found += Self.writes(base, cut)
            mark.cwd = mark.cwd ?? Self.firstCwd(base, cut)
            tail = Self.writes(base + cut, buf.count - cut)
            tailCwd = Self.firstCwd(base + cut, buf.count - cut)
            mark.offset += cut
        }
        mark.size = st.size
        mark.mtime = st.mtime
        marks.transcripts[transcript] = mark
        let fileCwd = mark.cwd ?? tailCwd
        let session = WritingSession.claude(transcript: transcript, cwd: fileCwd)
        return (mark.found + tail).compactMap { hit($0.path, cwd: $0.cwd ?? fileCwd, session: session) }
    }

    /// The file from `offset` on (mapped when whole); empty when nothing follows it.
    private static func read(_ path: String, from offset: Int) -> Data? {
        if offset == 0 { return try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(offset))
            return try h.readToEnd() ?? Data()
        } catch { return nil }
    }

    /// The .md writes in `n` bytes of whole lines, each with its own line's cwd.
    private static func writes(_ base: UnsafeRawPointer, _ n: Int) -> [Found] {
        var found: [Found] = []
        var pos = 0
        while pos < n, let at = find(".md\"", base + pos, n - pos).map({ $0 + pos }) {
            var start = at
            while start > pos && base.load(fromByteOffset: start - 1, as: UInt8.self) != 10 { start -= 1 }
            let end = memchr(base + at, 10, n - at).map { base.distance(to: UnsafeRawPointer($0)) } ?? n
            pos = end + 1
            guard find("\"tool_use\"", base + start, end - start) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(bytes: base + start, count: end - start)) as? [String: Any]
            else { continue }
            let cwd = obj["cwd"] as? String
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content where item["type"] as? String == "tool_use" {
                guard let name = item["name"] as? String, ["Write", "Edit", "MultiEdit"].contains(name),
                      let path = (item["input"] as? [String: Any])?["file_path"] as? String,
                      path.lowercased().hasSuffix(".md") else { continue }
                found.append(Found(path: path, cwd: cwd))
            }
        }
        return found
    }

    private static func find(_ needle: String, _ base: UnsafeRawPointer, _ count: Int) -> Int? {
        var needle = needle
        return needle.withUTF8 { n in
            memmem(base, count, n.baseAddress, n.count).map { base.distance(to: UnsafeRawPointer($0)) }
        }
    }

    /// The first `"cwd":"…"` value in the file, as a fallback for lines without one.
    private static func firstCwd(_ base: UnsafeRawPointer, _ n: Int) -> String? {
        guard let at = find("\"cwd\":\"", base, n) else { return nil }
        var i = at + 6
        var escaped = false
        while i + 1 < n {
            i += 1
            let c = base.load(fromByteOffset: i, as: UInt8.self)
            if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 || c == 10 { break }
        }
        let quoted = Data(bytes: base + at + 6, count: i - at - 5)
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }

    /// A Codex session: its cwd and the time it ran, then the .md files under the cwd changed then.
    func codexHits(_ session: String) -> [Hit] {
        guard let s = codexSession(session), s.cwd != env.home, s.cwd != "/", !isExcluded(s.cwd + "/") else { return [] }
        let from = s.start.addingTimeInterval(-60), to = s.end.addingTimeInterval(60)
        let writer = WritingSession.codex(rollout: session, cwd: s.cwd)
        var out: [Hit] = []
        walk(s.cwd, skip: { $0.hasPrefix(".") || ["node_modules", "build", "dist"].contains($0) }) { path, m in
            if m >= from && m <= to, let h = hit(path, cwd: s.cwd, session: writer) { out.append(h) }
        }
        return out
    }

    /// Read again only when its size or mtime changed since `previous` (the read maps the file and
    /// touches just its first lines and its last).
    func codexSession(_ path: String) -> CodexRun? {
        guard let st = Self.stamp(path) else { return nil }
        if let m = marks.sessions[path] ?? previous.sessions[path], m.size == st.size, m.mtime == st.mtime {
            marks.sessions[path] = m
            return m.run
        }
        let run = readCodexSession(path)
        marks.sessions[path] = SessionMark(size: st.size, mtime: st.mtime, run: run)
        return run
    }

    private func readCodexSession(_ path: String) -> CodexRun? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), !data.isEmpty else { return nil }
        var lines: [[String: Any]] = []
        var at = data.startIndex
        while lines.count < 5, at < data.endIndex {
            let end = data[at...].firstIndex(of: 10) ?? data.endIndex
            if let o = try? JSONSerialization.jsonObject(with: data[at..<end]) as? [String: Any] { lines.append(o) }
            at = end + 1
        }
        guard let cwd = lines.lazy.compactMap({ Self.findCwd($0) }).first else { return nil }
        var tail = data.endIndex
        while tail > data.startIndex && (data[tail - 1] == 10 || data[tail - 1] == 13) { tail -= 1 }
        let lastStart = data[..<tail].lastIndex(of: 10).map { $0 + 1 } ?? data.startIndex
        let last = try? JSONSerialization.jsonObject(with: data[lastStart..<tail]) as? [String: Any]
        let attrs = try? fm.attributesOfItem(atPath: path)
        let start = Self.date(lines.first?["timestamp"]) ?? attrs?[.creationDate] as? Date ?? .distantPast
        let end = Self.date(last?["timestamp"]) ?? attrs?[.modificationDate] as? Date ?? env.now
        return CodexRun(cwd: cwd, start: start, end: end)
    }

    private static func findCwd(_ any: Any) -> String? {
        if let d = any as? [String: Any] {
            if let c = d["cwd"] as? String, c.hasPrefix("/") { return c }
            return d.values.lazy.compactMap(findCwd).first
        }
        if let a = any as? [Any] { return a.lazy.compactMap(findCwd).first }
        return nil
    }

    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(s, strategy: .iso8601))
    }

    // ponytail: walks stop after 20k entries; a huge cwd loses its deepest files. Use FSEvents history if it matters.
    private func walk(_ root: String, skip: (String) -> Bool, _ visit: (String, Date) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys) else { return }
        var count = 0
        while let url = e.nextObject() as? URL {
            count += 1
            if count > 20_000 { break }
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { if skip(name) { e.skipDescendants() }; continue }
            if name.lowercased().hasSuffix(".md"), let m = v?.contentModificationDate { visit(url.path, m) }
        }
    }

    // MARK: Projects

    /// A hit for a written path, or nil when it is excluded.
    func hit(_ raw: String, cwd: String?, session: WritingSession? = nil) -> Hit? {
        var path = raw
        if !path.hasPrefix("/"), let cwd { path = cwd + "/" + path }
        guard path.hasPrefix("/") else { return nil }
        path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard !isExcluded(path) else { return nil }
        return Hit(path: path, project: project(path, cwd: cwd), session: session)
    }

    /// The file's repo root; outside a repo (and anything under ~/.claude), the writing session's project.
    func project(_ path: String, cwd: String?) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let session = cwd.map { repoRoot($0) ?? $0 } ?? dir
        return repoRoot(dir) ?? session
    }

    /// Walks up to a `.git` folder; a worktree's `.git` file points back to its main repo.
    func repoRoot(_ dir: String) -> String? {
        if let cached = roots[dir] { return cached }
        let root = computeRoot(dir)
        roots[dir] = root
        return root
    }

    private func computeRoot(_ dir: String) -> String? {
        if dir == claudeDir || dir.hasPrefix(claudeDir + "/") || dir == "/" || dir.isEmpty { return nil }
        let git = dir + "/.git"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: git, isDirectory: &isDir) {
            if isDir.boolValue { return dir }
            if let text = try? String(contentsOfFile: git, encoding: .utf8),
               let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                var gd = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if !gd.hasPrefix("/") { gd = dir + "/" + gd }
                gd = (gd as NSString).standardizingPath
                if let r = gd.range(of: "/.git/worktrees/") { return String(gd[..<r.lowerBound]) }
            }
            return dir
        }
        return repoRoot((dir as NSString).deletingLastPathComponent)
    }

    // MARK: Documents

    /// Hits into documents. The first hit of a path decides its project and writing session, so
    /// pass the newest sources first. A missing path shows as deleted only when a previous scan knew it.
    // ponytail: "newest" holds per agent (the scan lists all Claude sources before Codex ones), so a
    // doc both wrote resumes Claude. Merge the sources by mtime if that matters.
    func docs(_ hits: [Hit], known: [String: KnownDoc]) -> [DocInfo] {
        var projectOf: [String: String] = [:]
        var variantsOf: [String: [DocVariant]] = [:]
        var sessionOf: [String: WritingSession] = [:]
        var sessionsOf: [String: [WritingSession]] = [:]
        for h in hits {
            let (id, lang) = Library.split(h.path)
            if let s = h.session, !(sessionsOf[id] ?? []).contains(s) { sessionsOf[id, default: []].append(s) } // every writer, newest first
            guard projectOf[h.path] == nil else { continue }
            projectOf[h.path] = h.project
            if sessionOf[id] == nil { sessionOf[id] = h.session }
            variantsOf[id, default: []].append(DocVariant(lang: lang, path: h.path))
        }
        var out: [DocInfo] = []
        for (id, all) in variantsOf {
            let sorted = all.sorted { ($0.lang ?? "") < ($1.lang ?? "") }
            let project = projectOf[sorted[0].path]!
            let dir = (id as NSString).deletingLastPathComponent
            let folder = Library.folderLine(dir: dir, root: project, home: env.home)
            let present = sorted.compactMap { v in Self.mtime(v.path).map { (v, $0) } }
            guard let main = present.first else {
                if let k = known[id] {
                    out.append(DocInfo(id: id, project: project, variants: sorted, modified: k.modified, title: k.title, folder: folder,
                                       fixedKind: k.kind, ruleKind: k.kind, modelKey: nil, excerpt: "", deleted: true, session: sessionOf[id], sessions: sessionsOf[id]))
                }
                continue
            }
            let head = head(main.0.path, mtime: main.1)
            let name = (id as NSString).lastPathComponent
            let title = head.title ?? name
            let fixed = head.kind ?? Library.locationKind(id, home: env.home)
            let relDir = dir == project ? "" : dir.hasPrefix(project + "/") ? String(dir.dropFirst(project.count + 1)) : dir
            let rule = Library.ruleKind(stem: String(name.dropLast(3)), relDir: relDir, title: title, headings: head.headings)
            out.append(DocInfo(id: id, project: project, variants: present.map(\.0), modified: present.map(\.1).max()!,
                               title: title, folder: folder, fixedKind: fixed, ruleKind: rule,
                               modelKey: fixed == nil ? "\(main.0.path)|\(Int(main.1.timeIntervalSince1970))" : nil,
                               excerpt: head.excerpt, deleted: false, session: sessionOf[id], sessions: sessionsOf[id]))
        }
        return out
    }

    private func head(_ path: String, mtime: Date) -> DocHead {
        if let c = heads[path], c.mtime == mtime { return c.head }
        var head = DocHead()
        if let h = FileHandle(forReadingAtPath: path) {
            let data = (try? h.read(upToCount: 16_384)) ?? Data()
            try? h.close()
            head = Library.parseHead(String(decoding: data, as: UTF8.self))
        }
        heads[path] = (mtime, head)
        return head
    }
}
