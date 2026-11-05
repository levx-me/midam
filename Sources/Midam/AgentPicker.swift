import SwiftUI

/// File > New Agent… (⌘N): pick up a recent conversation, or start one in a new project.
/// A click only selects a conversation and shows its project beside the list; Open (Return, ⌘↩)
/// or a double-click resumes it, like an open panel.
struct AgentPicker: View {
    @ObservedObject var store: Store
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var installed: Bool?
    @State private var recent: [RecentSession]?
    @State private var query = ""
    @State private var selection: RecentSession.ID?
    /// Project root → its document count; nil inside when it couldn't be counted.
    @State private var docCounts: [String: Int?] = [:]
    @State private var name = ""
    @State private var nameError: LocalizedStringKey?
    @State private var creating = false
    @State private var opened = false
    @FocusState private var nameFocused: Bool
    @FocusState private var listFocused: Bool

    private var shown: [RecentSession] { recent?.filter { $0.matches(query) } ?? [] }
    private var selected: RecentSession? { selection.flatMap { id in recent?.first { $0.id == id } } }

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
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        TextField("Search conversations", text: $query).textFieldStyle(.roundedBorder)
                            .onKeyPress(.downArrow) { // from the search field into the list
                                if selection == nil { selection = shown.first?.id }
                                listFocused = true
                                return .handled
                            }
                        list
                    }
                    .frame(width: 300)
                    details
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: 300)
                Divider()
                Text("Or start a new project").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Project name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onSubmit(create)
                            .accessibilityValue(nameError.map { Text($0) } ?? Text(verbatim: ""))
                        if let nameError {
                            Text(nameError).font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                    // Return creates while the name field is focused, and opens the selection otherwise.
                    Button("Create", action: create)
                        .keyboardShortcut(nameFocused ? .defaultAction : nil)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if installed != false {
                    Button("Open") { open(selection) }
                        .keyboardShortcut(nameFocused ? nil : .defaultAction)
                        .disabled(selected == nil)
                        .background { // ⌘↩ opens too, from anywhere in the sheet
                            Button("Open") { open(selection) }
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(selected == nil)
                                .opacity(0).accessibilityHidden(true)
                        }
                }
            }
        }
        .padding(18)
        .frame(width: 660)
        .task {
            installed = await store.host.claudeInstalled()
            recent = await store.host.recentSessions(limit: 300).filter { $0.agent == .claude }
            selection = AgentPickerRules.keep(selection, in: shown.map(\.id))
        }
        .onChange(of: query) { selection = AgentPickerRules.keep(selection, in: shown.map(\.id)) }
        .task(id: selected?.projectRoot) { await countDocs(selected?.projectRoot) }
    }

    @ViewBuilder private var list: some View {
        if let recent {
            if shown.isEmpty {
                (recent.isEmpty ? Text("No earlier conversations yet.") : Text("Nothing matches."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown, selection: $selection) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: s.topic).lineLimit(1)
                        Text(verbatim: s.projectName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.bordered)
                .focused($listFocused)
                .contextMenu(forSelectionType: RecentSession.ID.self) { ids in
                    Button("Open") { open(ids.first) }
                } primaryAction: { ids in open(ids.first) } // double-click
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selected conversation's project: where it lives, when it was last used, its
    /// documents and its conversations.
    @ViewBuilder private var details: some View {
        if let s = selected {
            let sessions = AgentPickerRules.sessions(in: s.projectRoot, recent ?? [])
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: s.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(verbatim: AgentPickerRules.parent(s.projectRoot))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help(Text(verbatim: AgentPickerRules.friendly(s.projectRoot)))
                    .accessibilityElement(children: .combine)
                }
                Form {
                    LabeledContent("Last active") {
                        Text(sessions.first?.lastActive ?? s.lastActive, format: .relative(presentation: .named))
                    }
                    LabeledContent("Documents") { docCount(s.projectRoot) }
                }
                .formStyle(.columns)
                .font(.system(size: 12))
                Divider()
                Text("Conversations").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions) { c in row(c, current: c.id == s.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        } else if recent?.isEmpty == false {
            Text("Select a conversation to see its project.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ c: RecentSession, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                .opacity(current ? 1 : 0).accessibilityHidden(true)
            Text(verbatim: c.topic).font(.system(size: 12)).lineLimit(1)
            if store.agents.contains(where: { $0.session == c.sessionID }) {
                Text("In a tab").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(c.lastActive, format: .relative(presentation: .named))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private func docCount(_ root: String) -> some View {
        switch docCounts[root] {
        case .none: ProgressView().controlSize(.mini)
        case .some(.none): Text(verbatim: "–").foregroundStyle(.secondary)
        case .some(.some(let n)): Text(n, format: .number)
        }
    }

    /// The library's count for a registered project; otherwise the project folder is walked once.
    private func countDocs(_ root: String?) async {
        guard let root, docCounts[root] == nil else { return }
        if let p = library.projects.first(where: { $0.id == root }) { docCounts[root] = p.docCount; return }
        guard AgentPickerRules.countable(root) else { docCounts[root] = .some(nil); return }
        let n = try? await store.host.documents(project: root).count
        docCounts[root] = .some(n)
    }

    private func open(_ id: RecentSession.ID?) {
        guard !opened, let s = id.flatMap({ id in recent?.first { $0.id == id } }) else { return }
        opened = true
        dismiss()
        store.openAgent(project: s.projectRoot, resume: s.sessionID)
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
                SidebarState.shared.reveal = [project] // listed already: selected and scrolled to
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
