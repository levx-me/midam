// Checks the table of contents rules. Run:
// swiftc Sources/Midam/TocRules.swift tools/TocTest/main.swift -o /tmp/toc && /tmp/toc
import Foundation

// A render's result as WebKit bridges it: NSDictionary, NSArray, NSNumber (JS numbers may be doubles).
let item = { (level: Any, text: Any, id: Any) -> NSDictionary in ["level": level, "text": text, "id": id] }
let result: NSDictionary = ["outline": [item(NSNumber(value: 1.0), "Top", "top"), item(NSNumber(value: 2), "Same", "same"),
                                        item(NSNumber(value: 4), "Deep", "deep"), item(NSNumber(value: 2.5), "Half", "half"),
                                        item(2, "", "empty"), item(2, "No id", ""), item(3, "<b>x</b>", "x"),
                                        item(2, "Long id", String(repeating: "i", count: 513))] as NSArray,
                            "current": "same"]
guard let toc = Heading.toc(result) else { fatalError("the outline did not decode") }
assert(toc.outline.map(\.level) == [1, 2, 3] && toc.outline.map(\.anchor) == ["top", "same", "x"])
assert(toc.outline.map(\.id) == [0, 1, 6])          // positions in the reported list
assert(toc.outline[2].text == "<b>x</b>")           // shown as text, never parsed
assert(toc.current == "same")
assert(Heading.toc(["outline": [] as NSArray, "current": ""] as NSDictionary).map { $0.outline.isEmpty && $0.current == nil } == true)
assert(Heading.toc(["outline": toc.outline.isEmpty, "current": "x"] as NSDictionary) == nil) // not an outline
assert(Heading.toc(nil) == nil && Heading.toc("mermaid") == nil)
assert(Heading.anchor("nowhere", in: toc.outline) == nil && Heading.anchor(42, in: toc.outline) == nil)
assert(Heading.anchor("top", in: toc.outline) == "top")
let many = NSArray(array: (0..<600).map { item(2, "h\($0)", "h\($0)") })
assert(Heading.outline(many)?.count == 500)
// The first-showing hint.
assert(TocIntro.end(hovered: false, leftAt: nil) == 1.8)                    // it ends by itself
assert(TocIntro.end(hovered: false, leftAt: 3) == 3.6)                      // hovered, then left: 0.6 s later
assert(TocIntro.end(hovered: false, leftAt: 0.5) == 1.8)                    // left early: not before 1.8 s
assert(TocIntro.end(hovered: true, leftAt: nil) == 6 && TocIntro.end(hovered: false, leftAt: 9) == 6) // stuck hover: the cap
assert(TocIntro.shown(available: true, open: false, intro: true))
assert(!TocIntro.shown(available: true, open: false, intro: false))         // toggled during the hint: the toggle decides
assert(TocIntro.shown(available: true, open: true, intro: false))
assert(!TocIntro.shown(available: false, open: true, intro: true))
assert(!TocIntro.starts(introduced: false, available: true, open: true))    // already open: no hint
assert(!TocIntro.starts(introduced: true, available: true, open: false))    // once per tab
assert(TocIntro.starts(introduced: false, available: true, open: false))
print("toc rules: checks passed")
