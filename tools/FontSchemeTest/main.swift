// Checks the midam-font file-name rule. Run:
// swiftc Sources/Midam/FontScheme.swift tools/FontSchemeTest/main.swift -o /tmp/f && /tmp/f
import Foundation

let pass = ["midam-font:///PretendardVariable.woff2", "midam-font:///D2Coding-Bold.woff2", "midam-font:///a_b.c-1.woff2",
            "midam-font:///KaTeX_Main-Regular.woff2", "midam-font:///KaTeX_AMS-Regular.woff2"]
let fail = ["midam-font:///../x.woff2", "midam-font:///a/b.woff2", "midam-font:///x.ttf", "midam-font:///",
            "midam-font:///.woff2x", "midam-font:///a%2Fb.woff2", "midam-font:///..%2Fx.woff2", "midam-font:///x..woff2",
            "midam-font://host/x.woff2", "midam-font:///x.woff2?y", "midam-font:///x.woff2#y", "file:///x.woff2",
            "midam-font:///x.woff2/", "midam-font:///%2E%2E/x.woff2", "midam-font:///x%00.woff2"]
var bad = 0
for s in pass where bundledFontFileName(URL(string: s)!) == nil { print("should pass:", s); bad += 1 }
for s in fail { if let u = URL(string: s), let n = bundledFontFileName(u) { print("should fail:", s, "->", n); bad += 1 } }
print(bad == 0 ? "font scheme: \(pass.count) valid names pass, \(fail.count) bad ones fail" : "FAILED")
exit(bad == 0 ? 0 : 1)
