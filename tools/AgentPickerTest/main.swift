// Checks the New Agent picker's rules: friendly paths, the selection as the list filters, a
// project's sessions. Run:
// swiftc Sources/Midam/Library.swift Sources/Midam/Projects.swift tools/AgentPickerTest/main.swift -o /tmp/agentpicker && /tmp/agentpicker
import Foundation

let home = "/Users/ana"
assert(AgentPickerRules.friendly("/Users/ana/workspace/midam", home: home) == "~/workspace/midam")
assert(AgentPickerRules.friendly("/Users/ana", home: home) == "~")
assert(AgentPickerRules.friendly("/Users/ana/", home: home + "/") == "~/")
assert(AgentPickerRules.friendly("/Users/ana/x", home: home + "/") == "~/x")
assert(AgentPickerRules.friendly("/Users/anabel/x", home: home) == "/Users/anabel/x") // a sibling with the same prefix
assert(AgentPickerRules.friendly("/opt/work", home: home) == "/opt/work")
assert(AgentPickerRules.parent("/Users/ana/workspace/midam", home: home) == "~/workspace")
assert(AgentPickerRules.parent("/Users/ana/notes", home: home) == "~")
assert(AgentPickerRules.parent("/srv/app", home: home) == "/srv")
assert(AgentPickerRules.countable("/Users/ana/notes", home: home))
assert(!AgentPickerRules.countable("/Users/ana", home: home) && !AgentPickerRules.countable("/", home: home))

// Selection: kept while shown, else the first shown row, nil when nothing is shown.
assert(AgentPickerRules.keep("b", in: ["a", "b"]) == "b")
assert(AgentPickerRules.keep("c", in: ["a", "b"]) == "a")
assert(AgentPickerRules.keep(nil, in: ["a", "b"]) == "a")
assert(AgentPickerRules.keep("a", in: []) == nil)

let now = Date()
func s(_ id: String, _ root: String, _ age: TimeInterval) -> RecentSession {
    RecentSession(agent: .claude, sessionID: id, projectRoot: root, topic: "topic " + id, lastActive: now.addingTimeInterval(-age))
}
let all = [s("1", "/p/a", 50), s("2", "/p/b", 10), s("3", "/p/a", 5), s("4", "/p/ab", 1)]
assert(AgentPickerRules.sessions(in: "/p/a", all).map(\.sessionID) == ["3", "1"])
assert(AgentPickerRules.sessions(in: "/p/c", all).isEmpty)
print("agent picker: all checks passed")
