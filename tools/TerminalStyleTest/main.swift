// Checks the terminal settings' values: clamping, cursor tags, theme palettes. Run:
// swiftc Sources/Midam/TerminalStyle.swift tools/TerminalStyleTest/main.swift -o /tmp/termstyle && /tmp/termstyle
import Foundation

let d = TerminalStyle()
assert(d.family == "" && d.size == 13 && d.spacing == 1 && d.theme == .system && d.cursor == .block && d.blink)
assert(d.cursorTag == "blinkBlock")                                        // SwiftTerm's own default
assert(TerminalStyle(cursor: "bar", blink: false).cursorTag == "steadyBar")
assert(TerminalStyle(cursor: "underline").cursorTag == "blinkUnderline")
assert(TerminalStyle(cursor: "beam").cursor == .block)                      // unknown: the default
assert(TerminalStyle(theme: "nope").theme == .system)
assert(TerminalStyle(size: 2).size == 9 && TerminalStyle(size: 99).size == 24)
assert(TerminalStyle(spacing: 0.5).spacing == 1 && TerminalStyle(spacing: 3).spacing == 1.6)

func lum(_ c: UInt32) -> Double {
    let ch = [c >> 16 & 0xff, c >> 8 & 0xff, c & 0xff].map { v -> Double in
        let s = Double(v) / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
}
for t in TerminalTheme.allCases {
    assert(t.ansi.count == 16, "\(t): SwiftTerm ignores a palette without 16 colours")
    assert(!t.name.isEmpty)
    guard let fg = t.fg, let bg = t.bg else { assert(t == .system); continue }
    let (a, b) = (lum(fg), lum(bg))
    let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
    assert(ratio >= 4.5, "\(t): text contrast \(ratio) below WCAG AA")
}
print("terminal style: checks passed")
