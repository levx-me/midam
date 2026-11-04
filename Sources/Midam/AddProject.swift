import AppKit
import SwiftUI

// Add Project: the projects in every agent's history (any age) that the sidebar does not list,
// by agent, to collect from now on (LibraryModel.add). No file picker: a project is something an
// agent worked on.

@MainActor enum AddProject {
    /// File > Add Project…, the + of All Projects, and the empty sidebar's button.
    static func show() {
        let store = Store.shared
        store.sidebarOpen = true
        store.showWindow()
        SidebarState.shared.addingProject = true
    }
}

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryModel.shared
    /// nil while the history is being read.
    @State private var found: [ProjectCandidate]?
    /// Documents per candidate id, filled in one by one after the list shows.
    @State private var counts: [String: Int] = [:]
    @State private var chosen: Set<String> = [] // project roots
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// What the sidebar does not list (hidden ones included), matching the search.
    private var shown: [ProjectCandidate] {
        let listed = Set(library.projects.map(\.id))
        return (found ?? []).filter { c in
            !listed.contains(c.root) && (query.isEmpty || !Library.ranges(of: query, in: (c.root as NSString).abbreviatingWithTildeInPath).isEmpty)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Project")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Projects your agents worked on that are not in the sidebar. Midam gathers their documents from all of their history.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)
            search
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if !chosen.isEmpty {
                    Text(verbatim: String(format: String(localized: "%lld selected"), chosen.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 540)
        .task { await load() }
        .onAppear { searchFocused = true }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search Projects", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if found == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking through agent history…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if shown.isEmpty {
            Group {
                if query.isEmpty { Text("Every project in your agents’ history is already in the sidebar.") }
                else { Text(verbatim: String(format: String(localized: "No projects match “%@”."), query)) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
        } else {
            List {
                ForEach(Agent.allCases, id: \.self) { agent in
                    let rows = shown.filter { $0.agent == agent }
                    if !rows.isEmpty {
                        Section { ForEach(rows) { row($0) } } header: { Text(verbatim: agent.name) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ c: ProjectCandidate) -> some View {
        let count = counts[c.id]
        let name = (c.root as NSString).lastPathComponent
        return Toggle(isOn: Binding(get: { chosen.contains(c.root) },
                                    set: { if $0 { chosen.insert(c.root) } else { chosen.remove(c.root) } })) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(verbatim: name).fontWeight(.medium).lineLimit(1)
                        if library.hidden.contains(c.root) {
                            Text("Hidden")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(.secondary, lineWidth: 0.5))
                                .fixedSize()
                        }
                    }
                    Text(verbatim: (c.root as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: Words.ago(c.lastSession))
                    Group {
                        if let count { Text(verbatim: Words.documents(count)) }
                        else { ProgressView().controlSize(.mini).accessibilityLabel("Counting documents…") }
                    }
                    .frame(height: 14)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .toggleStyle(.checkbox)
        .disabled(count == 0) // nothing to show yet
        .padding(.vertical, 2)
        .accessibilityLabel(Text(verbatim: [name, Words.ago(c.lastSession), count.map(Words.documents) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
    }

    /// Reads the history off the main thread, then counts each listed project's documents.
    private func load() async {
        let env = ScanEnv.standard()
        let all = await Task.detached(priority: .userInitiated) { LibraryScanner(env: env).candidates() }.value
        found = all
        for c in shown {
            if Task.isCancelled { return }
            counts[c.id] = await Task.detached(priority: .utility) { LibraryScanner(env: env).docCount(c) }.value
        }
    }

    private func add() {
        let roots = chosen
        SidebarState.shared.reveal = Array(roots)
        library.add(roots)
        AccessibilityNotification.Announcement(String(format: String(localized: "Projects added: %lld"), roots.count)).post()
        dismiss()
    }
}

extension Agent {
    /// Product names, not translated.
    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}
