import Foundation

// Tabs belong to a project: each keeps its own documents and agents, in order, with the one
// selected; switching projects swaps the whole strip. Saved in UserDefaults ("projectTabs").

/// What an agent tab remembers across launches: it comes back without running until the person
/// sends (or, for a terminal, presses Restart).
struct AgentTabSave: Codable, Equatable {
    var session: String?
    var project: String
    var terminal = false
    /// The project's preview (its address) rather than a conversation.
    var preview: String?
}

/// One project's tabs: document paths, then agents; `selected` indexes that combined order.
struct ProjectTabsSave: Codable, Equatable {
    var files: [String] = []
    var agents: [AgentTabSave] = []
    var selected: Int?
}

struct TabsSave: Codable, Equatable {
    var current: String?
    var projects: [String: ProjectTabsSave] = [:]

    /// Last version's single list of open files ("openFiles", "selectedFile"), grouped by project.
    static func migrate(files: [String], selected: String?, root: (String) -> String) -> TabsSave {
        var save = TabsSave()
        for f in files {
            let r = root(f)
            var p = save.projects[r] ?? ProjectTabsSave()
            p.files.append(f)
            if f == selected { save.current = r; p.selected = p.files.count - 1 }
            save.projects[r] = p
        }
        if save.current == nil { save.current = files.first.map(root) }
        return save
    }
}

enum ProjectRoot {
    /// The project a document belongs to: the deepest registered project holding it, else the git
    /// repository around it, else its own folder. `registered` says whether it is one already.
    /// `isFolder`: `path` is a folder (an agent's working folder), not a document. The home folder,
    /// `/` and home's Desktop, Documents and Downloads are never taken as a repository (a dotfiles
    /// repo would swallow every loose file); only as a file's own folder.
    static func of(file path: String, registered: Set<String>, isFolder: Bool = false,
                   home: String = NSHomeDirectory(),
                   isRepo: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }) -> (root: String, registered: Bool) {
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let p = real(path)
        if let r = registered.filter({ let root = real($0); return p == root || p.hasPrefix(root + "/") })
            .max(by: { real($0).count < real($1).count }) {
            return (r, true)
        }
        let folder = isFolder ? p : (p as NSString).deletingLastPathComponent
        let broad = Set([home, home + "/Desktop", home + "/Documents", home + "/Downloads"].map(real))
        var dir = folder
        while dir != "/" && !dir.isEmpty {
            if !broad.contains(dir), isRepo(dir) { return (dir, false) }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return (folder, false)
    }
}
