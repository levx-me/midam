import AppKit
import SwiftUI

// A conversation with Claude in a tab beside the documents: the person's messages, the agent's
// replies as Markdown, its tool uses as one plain line each, and cards when it needs an OK or an
// answer. Everything goes through Store.host (AgentHost); no process or path is touched here.
// With Settings > Show as Terminal on, a new agent opens as the V5 terminal tab instead.

/// One agent tab: a conversation (session) or, in terminal mode, a terminal.
@MainActor final class AgentTab: ObservableObject, Identifiable {
    let id = UUID()
    /// The AgentHost session; nil for a terminal started fresh (it never learns its id).
    let session: String?
    let project: String
    /// The project whose tab strip holds it (a registered root; `project` may sit inside it).
    let group: String
    let terminal: AgentTerminal?
    /// Opened on earlier history: worth restoring even before its items arrive.
    var resumable = false
    @Published var items: [ChatItem] = []
    @Published var info: SessionInfo?
    @Published var draft = ""
    /// A turn finished while another tab was in front: "done" until the tab is shown.
    @Published var unseen = false

    init(session: String?, project: String, group: String? = nil, terminal: AgentTerminal? = nil) {
        self.session = session
        self.project = project
        self.group = group ?? project
        self.terminal = terminal
    }

    var projectName: String { (project as NSString).lastPathComponent }
    var title: String {
        if let terminal { return terminal.title }
        return info?.topic ?? String(format: String(localized: "Claude · %@"), projectName)
    }
    var state: Conversation.State { info?.state ?? .notStarted }
    /// A turn runs or waits for the person: closing or quitting asks first.
    var busy: Bool { terminal?.isRunning ?? (state == .working || state == .blocked) }
    var waiting: Bool { state == .blocked }
    var save: AgentTabSave { AgentTabSave(session: session, project: project, terminal: terminal != nil) }

    func upsert(_ item: ChatItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }
}

// MARK: - Conversation

struct ChatView: View {
    @ObservedObject var tab: AgentTab
    @ObservedObject var store: Store
    let ink: Color, muted: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if tab.items.isEmpty {
                        Text("Ask Claude for something: a plan, a document, a change to the app.")
                            .foregroundStyle(muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(tab.items) { item in
                        ChatRow(item: item, tab: tab, store: store, ink: ink, muted: muted,
                                last: item.id == tab.items.last(where: { if case .error = $0.kind { true } else { false } })?.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.top, store.header + 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: tab.items.last) {
                if reduceMotion { proxy.scrollTo("end", anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(tab: tab, store: store, muted: muted)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
        }
        // Links in replies and errors follow the documents' rules: web pages in the browser,
        // Markdown in Midam, any other file only shown in Finder, never opened or run.
        .environment(\.openURL, OpenURLAction { url in
            switch linkAction(url, current: nil) {
            case .browser(let url): NSWorkspace.shared.open(url)
            case .open(let target, let fragment): store.open(target, fragment: fragment)
            case .reveal(let target): NSWorkspace.shared.activateFileViewerSelecting([target])
            case .scroll, .ignore: break
            }
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: tab.title))
    }
}

private struct ChatRow: View {
    let item: ChatItem
    @ObservedObject var tab: AgentTab
    let store: Store
    let ink: Color, muted: Color
    let last: Bool
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .user(let text, let queued):
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: text)
                        .textSelection(.enabled)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if queued { Text("Waiting to send").font(.caption).foregroundStyle(muted) }
                }
                .opacity(queued ? 0.55 : 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("You: ") + Text(verbatim: text))
        case .assistant(let md, _):
            ChatMarkdownView(markdown: md, ink: ink, muted: muted)
        case .tool(_, let line, let subject, let detail, let status):
            VStack(alignment: .leading, spacing: 6) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Group {
                            switch status {
                            case .running: ProgressView().controlSize(.mini)
                            case .done: Image(systemName: "checkmark.circle")
                            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            }
                        }
                        .frame(width: 14)
                        Text(LocalizedStringKey(line))
                        if let subject { Text(verbatim: subject).foregroundStyle(muted).lineLimit(1) }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
                .accessibilityHint(Text("Shows what it did"))
                if open {
                    Text(verbatim: detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .permission(let sentence, let tool, let input, let answer):
            PermissionCard(sentence: sentence, tool: tool, input: input, answer: answer) { allow in
                guard let s = tab.session else { return }
                Task { try? await store.host.answer(s, permission: item.id, allow: allow) }
            }
        case .question(let questions, let answers):
            QuestionCard(questions: questions, answers: answers) { choices in
                guard let s = tab.session else { return }
                Task { try? await store.host.answer(s, question: item.id, choices: choices) }
            }
        case .error(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(LocalizedStringKey(text)).foregroundStyle(ink).textSelection(.enabled)
                Spacer(minLength: 0)
                if last, case .ended = tab.state {
                    Button("Restart") { store.restart(tab) }
                }
            }
            .font(.system(size: 13))
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .result:
            EmptyView() // cost and tokens: not for this audience
        }
    }
}

/// An agent reply drawn like a document: ChatMarkdown's blocks, inline Markdown inside them.
struct ChatMarkdownView: View {
    let markdown: String
    let ink: Color, muted: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    inline(text)
                case .item(let text, let marker, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: marker ?? "•").foregroundStyle(muted).monospacedDigit()
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .quote(let text):
                    inline(text).foregroundStyle(muted)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(muted.opacity(0.4)).frame(width: 3) }
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: text).font(.system(size: 12, design: .monospaced)).foregroundStyle(ink).textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(muted.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: 14))
        .lineSpacing(3)
        .foregroundStyle(ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }
}

// MARK: - Cards

/// "OK to go on?": a solid card with the plain reason, the details folded away, Deny and Allow.
private struct PermissionCard: View {
    let sentence: String, tool: String, input: String
    let answer: Bool?
    let reply: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("OK to go on?", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(LocalizedStringKey(sentence)).font(.system(size: 13))
            DisclosureGroup("Details") {
                Text(verbatim: tool + "\n" + input)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                if let answer {
                    Label { answer ? Text("Allowed") : Text("Not allowed") } icon: { Image(systemName: answer ? "checkmark" : "xmark") }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Deny") { reply(false) }
                    Button("Allow") { reply(true) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .modifier(SolidCard(highlight: answer == nil))
        .accessibilityElement(children: .contain)
    }
}

/// AskUserQuestion: each question with its options (one or several), the recommended one marked,
/// a preview of the chosen option, own words in "Other", and Submit once each has an answer.
private struct QuestionCard: View {
    let questions: [ChatItem.Question]
    let answers: [String: String]?
    let submit: ([String: [String]]) -> Void
    @State private var chosen: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    private func picks(_ i: Int) -> [String] {
        let own = other[i, default: ""].trimmingCharacters(in: .whitespaces)
        return questions[i].options.map(\.label).filter { chosen[i, default: []].contains($0) } + (own.isEmpty ? [] : [own])
    }
    private var ready: Bool { questions.indices.allSatisfy { !picks($0).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                VStack(alignment: .leading, spacing: 6) {
                    if !q.header.isEmpty {
                        Text(verbatim: q.header.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text(verbatim: q.question).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let answers {
                        Label { Text(verbatim: answers[q.question] ?? "—") } icon: { Image(systemName: "checkmark") }
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ForEach(q.options, id: \.label) { o in option(i, q, o) }
                        TextField("Other…", text: Binding(get: { other[i, default: ""] }, set: { other[i] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                        if let preview = q.options.first(where: { chosen[i, default: []].contains($0.label) })?.preview {
                            Text(verbatim: preview)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(Text("Preview"))
                        }
                    }
                }
            }
            if answers == nil {
                HStack {
                    Spacer()
                    Button("Submit") {
                        submit(Dictionary(uniqueKeysWithValues: questions.indices.map { (questions[$0].question, picks($0)) }))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
                }
            }
        }
        .modifier(SolidCard(highlight: answers == nil))
        .accessibilityElement(children: .contain)
    }

    private func option(_ i: Int, _ q: ChatItem.Question, _ o: ChatItem.Option) -> some View {
        let on = chosen[i, default: []].contains(o.label)
        let recommended = o.label.localizedCaseInsensitiveContains("(Recommended)")
        let label = recommended ? o.label.replacingOccurrences(of: "(Recommended)", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces) : o.label
        return Button {
            if q.multiSelect { chosen[i, default: []].formSymmetricDifference([o.label]) } else { chosen[i] = [o.label] }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: label).font(.system(size: 13, weight: .medium))
                        if recommended {
                            Text("Recommended").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    if !o.description.isEmpty { Text(verbatim: o.description).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(on ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Opaque card on the conversation (no glass under text), the accent edge while it waits.
private struct SolidCard: ViewModifier {
    let highlight: Bool
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlight ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: highlight ? 1.5 : 1))
    }
}

// MARK: - Composer

/// The message field in a glass capsule: Return (or ⌘Return) sends, Shift-Return starts a new line;
/// Send turns into Stop while a turn runs. Sending during a turn queues the message.
private struct Composer: View {
    @ObservedObject var tab: AgentTab
    let store: Store
    let muted: Color
    @FocusState private var focused: Bool

    private var empty: Bool { tab.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tab.waiting {
                Label("Waiting for you", systemImage: "hand.raised.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    // Sizes the field to its text (up to the cap); the editor itself does not grow.
                    Text(verbatim: tab.draft + " ").font(.system(size: 14)).hidden().padding(.vertical, 4).padding(.horizontal, 5)
                    if tab.draft.isEmpty {
                        Text("Message Claude").font(.system(size: 14)).foregroundStyle(muted)
                            .padding(.vertical, 4).padding(.horizontal, 5)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $tab.draft)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .accessibilityLabel(Text("Message Claude"))
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored } // a new line
                            send()
                            return .handled
                        }
                }
                .frame(minHeight: 24, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                if tab.state == .working, empty {
                    Button { if let s = tab.session { Task { try? await store.host.interrupt(s) } } } label: {
                        Image(systemName: "stop.fill").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.12), in: Circle())
                    .accessibilityLabel(Text("Stop"))
                    .help(Text("Stop"))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.opacity(empty ? 0.4 : 1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .accessibilityLabel(Text("Send"))
                    .help(Text("Send") + Text(verbatim: " (↩)"))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard !empty, let s = tab.session else { return }
        let text = tab.draft
        tab.draft = ""
        Task {
            do { try await store.host.send(s, text: text) } catch { tab.draft = text } // kept to try again
        }
    }
}

// MARK: - Terminal tab

/// The V5 terminal (Show as Terminal), with Restart over it once the agent has ended or not run yet.
struct TerminalTabView: View {
    @ObservedObject var terminal: AgentTerminal
    let top: CGFloat

    var body: some View {
        TerminalHost(terminal: terminal)
            .padding(.top, top)
            .overlay {
                if !terminal.isRunning {
                    VStack(spacing: 10) {
                        if case .ended = terminal.state { Text("Ended").font(.headline) }
                        Button("Restart") { terminal.start() }.buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
                }
            }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let terminal: AgentTerminal
    func makeNSView(context: Context) -> AgentTerminalView { terminal.view }
    func updateNSView(_ view: AgentTerminalView, context: Context) {}
}

// MARK: - Tab in the strip

struct AgentTabButton: View {
    @ObservedObject var tab: AgentTab
    @ObservedObject var store: Store
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let on = store.selected == tab.id
        Button { store.select(tab) } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.terminal == nil ? "bubble.left.and.text.bubble.right" : "apple.terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                Text(verbatim: tab.title)
                    .font(.system(size: 14, weight: on ? .medium : .regular))
                    .foregroundStyle(GlassLabel.style(strong: on, opaque: reduceTransparency))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
                Circle().fill(tab.waiting ? Color.accentColor : Color.green)
                    .frame(width: 6, height: 6)
                    .opacity(tab.waiting || tab.state == .working ? 1 : 0)
                Color.clear.frame(width: 20, height: 20) // room for the ×
            }
            .padding(.leading, 11)
            .padding(.trailing, 3)
            .frame(height: TitleStrip.capsule - 4)
            .background(Color.primary.opacity(on ? 0.09 : 0), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fastTip(Text(verbatim: tab.title + " · " + tab.projectName) + (tab.waiting ? Text(verbatim: "\n") + Text("Waiting for you") : Text(verbatim: "")))
        .accessibilityLabel(Text(verbatim: tab.title))
        .accessibilityValue(tab.waiting ? Text("Waiting for you") : tab.state == .working ? Text("Working…") : Text(verbatim: ""))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: Text("Close Tab")) { store.close(tab) }
        .overlay(alignment: .trailing) {
            Button { store.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .opacity(hover ? 1 : 0)
            .focusable(false)
            .accessibilityHidden(true)
        }
        .onHover { hover = $0 }
    }
}

// MARK: - Team (right panel)

/// The focused conversation's subagents as a tree, read again every second while it shows.
struct TeamPanel: View {
    @ObservedObject var store: Store
    @State private var root: TeamNode?

    var body: some View {
        if let tab = store.currentAgent, let session = tab.session, tab.terminal == nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let root {
                        ForEach(Self.rows(root), id: \.node.id) { row in TeamRow(node: row.node, depth: row.depth) }
                    } else {
                        PanelHint(text: Text("Nobody else is working on this yet."))
                    }
                }
                .padding(.horizontal, 10)
            }
            .task(id: session) {
                root = nil
                while !Task.isCancelled {
                    root = try? await store.host.team(session: session)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            PanelHint(text: Text("Open a conversation to see who is working on it."))
        }
    }

    static func rows(_ n: TeamNode, depth: Int = 0) -> [(node: TeamNode, depth: Int)] {
        [(n, depth)] + n.children.flatMap { rows($0, depth: depth + 1) }
    }
}

private struct TeamRow: View {
    let node: TeamNode
    let depth: Int

    private var color: Color {
        switch node.state {
        case .working: .green
        case .done: .secondary
        case .blocked: .accentColor
        case .failed: .red
        }
    }
    private var stateWord: LocalizedStringKey {
        switch node.state {
        case .working: "Working…"
        case .done: "Done"
        case .blocked: "Waiting for you"
        case .failed: "Stopped"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(verbatim: node.role).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    if let t = node.elapsed() {
                        Text(Duration.seconds(Int(t)).formatted(.time(pattern: t >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !node.doing.isEmpty { Text(verbatim: node.doing).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateWord))
    }
}

// MARK: - New Agent sheet

/// File > New Agent… (⌘N): pick up a recent conversation, or start one in a new project.
struct NewAgentSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var installed: Bool?
    @State private var recent: [RecentSession]?
    @State private var query = ""
    @State private var name = ""
    @State private var nameError: LocalizedStringKey?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if installed == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude isn't set up on this Mac yet.").font(.system(size: 13, weight: .medium))
                    Text("Install Claude Code from claude.com/code, sign in once in Terminal, then come back here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 20)
            } else {
                Text("Pick up an earlier conversation").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Search conversations", text: $query).textFieldStyle(.roundedBorder)
                list.frame(height: 220)
                Divider()
                Text("Or start a new project").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Project name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(create)
                            .accessibilityValue(nameError.map { Text($0) } ?? Text(verbatim: ""))
                        if let nameError {
                            Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                    Button("Create", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            installed = await store.host.claudeInstalled()
            recent = await store.host.recentSessions(limit: 300).filter { $0.agent == .claude }
        }
    }

    @ViewBuilder private var list: some View {
        if let recent {
            let shown = recent.filter { $0.matches(query) }
            if shown.isEmpty {
                (recent.isEmpty ? Text("No earlier conversations yet.") : Text("Nothing matches."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { s in
                    Button {
                        dismiss()
                        store.openAgent(project: s.projectRoot, resume: s.sessionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: s.topic).lineLimit(1)
                            Text(verbatim: s.projectName + " · ") + Text(s.lastActive, style: .relative)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.bordered)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func create() {
        guard !creating, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        creating = true
        nameError = nil
        Task {
            defer { creating = false }
            do {
                let project = try await store.host.createProject(name: name)
                dismiss()
                store.openAgent(project: project, resume: nil)
            } catch ProjectError.exists {
                nameError = "A project with that name already exists."
            } catch ProjectError.invalidName {
                nameError = "Use a name without / and not starting with a dot."
            } catch {
                nameError = "The project couldn't be set up."
            }
        }
    }
}
