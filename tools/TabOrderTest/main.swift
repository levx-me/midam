// Run: swiftc Sources/Midam/TabOrder.swift tools/TabOrderTest/main.swift -o /tmp/taborder && /tmp/taborder
let id = { (s: String) in s }
assert(mergeTabs(saved: ["demo", "second"], launched: ["fourth"], key: id) == ["demo", "second", "fourth"])
assert(mergeTabs(saved: ["demo", "second"], launched: ["demo"], key: id) == ["demo", "second"])
assert(mergeTabs(saved: [], launched: ["a", "b"], key: id) == ["a", "b"])
assert(mergeTabs(saved: ["a", "b"], launched: [], key: id) == ["a", "b"])
assert(mergeTabs(saved: ["a"], launched: ["b", "b"], key: id) == ["a", "b"])
print("tab order: 5 checks passed")
