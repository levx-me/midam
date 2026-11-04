// Checks the swipe-or-scroll rule. Run:
// swiftc Sources/Midam/SwipeRules.swift tools/SwipeTest/main.swift -o /tmp/swipe && /tmp/swipe
assert(SwipeRules.verdict(dx: 0, dy: -6) == .scroll)        // straight down
assert(SwipeRules.verdict(dx: 3, dy: -2) == .scroll)        // first sample leans sideways, still mostly down
assert(SwipeRules.verdict(dx: 12, dy: -6) == .scroll)       // diagonal: a scroll, never a swipe
assert(SwipeRules.verdict(dx: -10, dy: 5) == .scroll)       // either way round
assert(SwipeRules.verdict(dx: 0, dy: 0) == .scroll)         // no direction yet: leave it to the page
assert(SwipeRules.verdict(dx: 4, dy: 1) == .undecided)      // sideways, too short to tell
assert(SwipeRules.verdict(dx: 14.9, dy: 0) == .undecided)
assert(SwipeRules.verdict(dx: 15, dy: 0) == .swipe)         // far enough sideways
assert(SwipeRules.verdict(dx: -20, dy: 9) == .swipe)        // mostly sideways, to the left
print("swipe rules: checks passed")
