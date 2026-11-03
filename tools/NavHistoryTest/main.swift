// Run: swiftc Sources/Midam/NavHistory.swift tools/NavHistoryTest/main.swift -o /tmp/nav && /tmp/nav
var h = NavHistory<String>()
assert(!h.canGoBack && !h.canGoForward)
assert(h.goBack(from: "a") == nil && h.goForward(from: "a") == nil) // nowhere to go changes nothing
assert(!h.canGoForward)

h.leave("a")            // a -> b
h.leave("b")            // b -> c
assert(h.back == ["a", "b"])
assert(h.goBack(from: "c") == "b" && h.forward == ["c"])
assert(h.goBack(from: "b") == "a" && h.forward == ["c", "b"] && !h.canGoBack)
assert(h.goForward(from: "a") == "b" && h.back == ["a"] && h.forward == ["c"])
assert(h.goForward(from: "b") == "c" && h.back == ["a", "b"] && !h.canGoForward)

// A new place after going back drops the way forward.
_ = h.goBack(from: "c")
h.leave("b")            // b -> d
assert(h.back == ["a", "b"] && h.forward.isEmpty)

// Consecutive duplicates merge, on every side.
h.leave("b")
assert(h.back == ["a", "b"])
var g = NavHistory<String>()
g.leave("a"); g.leave("b"); g.leave("c")
assert(g.goBack(from: "d") == "c" && g.forward == ["d"])
assert(g.goBack(from: "d") == "b" && g.forward == ["d"])       // the same place is not stacked twice
assert(g.goForward(from: "b") == "d" && g.back == ["a", "b"])
assert(g.goForward(from: "b") == nil && g.back == ["a", "b"])  // nowhere further
print("nav history: checks passed")
