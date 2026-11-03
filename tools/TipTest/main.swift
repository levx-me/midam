// Checks the fast tooltip rules. Run:
// swiftc Sources/Midam/TipRules.swift tools/TipTest/main.swift -o /tmp/tip && /tmp/tip
assert(TipRules.wait(now: 10, showing: false, lastHidden: nil) == 0.4)   // the first one waits
assert(TipRules.wait(now: 10, showing: true, lastHidden: nil) == 0)      // moving on while one shows
assert(TipRules.wait(now: 10, showing: false, lastHidden: 9.7) == 0)     // to a neighbour: at once
assert(TipRules.wait(now: 10, showing: false, lastHidden: 9.4) == 0.4)   // left the header: cold again
assert(TipRules.x(mid: 100, width: 80, container: 900) == 60)            // centred
assert(TipRules.x(mid: 10, width: 80, container: 900) == 8)              // kept off the left edge
assert(TipRules.x(mid: 890, width: 80, container: 900) == 812)           // and the right
assert(TipRules.y(top: 3, bottom: 29, height: 20, container: 700) == 35) // below the control
assert(TipRules.y(top: 680, bottom: 690, height: 20, container: 700) == 654) // above it near the bottom
print("tip rules: checks passed")
