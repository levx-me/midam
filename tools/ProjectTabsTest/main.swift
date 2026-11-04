// Run: swiftc Sources/Midam/ProjectTabs.swift tools/ProjectTabsTest/main.swift -o /tmp/projecttabs && /tmp/projecttabs
import Foundation

// Which project a document belongs to.
let repos: Set<String> = ["/w/app", "/w/mono", "/h", "/h/Downloads", "/"]
let isRepo = { (d: String) in repos.contains(d) }
func root(_ p: String, _ reg: Set<String> = []) -> (String, Bool) {
    let r = ProjectRoot.of(file: p, registered: reg, home: "/h", isRepo: isRepo)
    return (r.root, r.registered)
}
assert(root("/w/app/docs/plan.md", ["/w/app"]) == ("/w/app", true))
assert(root("/w/mono/pkg/a/x.md", ["/w/mono", "/w/mono/pkg/a"]) == ("/w/mono/pkg/a", true)) // the deepest
assert(root("/w/app/docs/plan.md") == ("/w/app", false)) // the repository around it
assert(root("/w/notes/today.md") == ("/w/notes", false)) // its own folder
assert(root("/w/apple/x.md", ["/w/app"]) == ("/w/apple", false)) // a prefix is not a parent
assert(ProjectRoot.of(file: "/w/app/sub", registered: [], isFolder: true, home: "/h", isRepo: isRepo) == ("/w/app", false)) // an agent's folder
// Home, / and home's Downloads are never taken as the repository around a file (dotfiles repos).
assert(root("/h/notes/today.md") == ("/h/notes", false))
assert(root("/h/Downloads/spec/x.md") == ("/h/Downloads/spec", false))
assert(root("/h/Downloads/x.md") == ("/h/Downloads", false)) // its own folder still
assert(root("/srv/x.md") == ("/srv", false))

// Saved tabs round-trip, and last version's list groups by project.
var save = TabsSave(current: "/a", projects: ["/a": ProjectTabsSave(files: ["/a/x.md"], agents: [AgentTabSave(session: "s1", project: "/a")], selected: 1),
                                              "/b": ProjectTabsSave(agents: [AgentTabSave(session: nil, project: "/b", terminal: true)])])
assert(try! JSONDecoder().decode(TabsSave.self, from: JSONEncoder().encode(save)) == save)
save = TabsSave.migrate(files: ["/a/1.md", "/b/2.md", "/a/3.md"], selected: "/a/3.md") { ($0 as NSString).deletingLastPathComponent }
assert(save.current == "/a")
assert(save.projects["/a"] == ProjectTabsSave(files: ["/a/1.md", "/a/3.md"], selected: 1))
assert(save.projects["/b"] == ProjectTabsSave(files: ["/b/2.md"]))
print("project tabs: 14 checks passed")
