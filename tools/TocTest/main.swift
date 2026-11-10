// Checks the table of contents rules. Run:
// swiftc Sources/Midam/TocRules.swift tools/TocTest/main.swift -o /tmp/toc && /tmp/toc
import Foundation

// A render's result as WebKit bridges it: NSDictionary, NSArray, NSNumber (JS numbers may be doubles).
let item = { (level: Any, text: Any, id: Any) -> NSDictionary in ["level": level, "text": text, "id": id] }
let result: NSDictionary = ["outline": [item(NSNumber(value: 1.0), "Top", "top"), item(NSNumber(value: 2), "Same", "same"),
                                        item(NSNumber(value: 4), "Deep", "deep"), item(5, "Deeper", "deeper"), item(NSNumber(value: 2.5), "Half", "half"),
                                        item(2, "", "empty"), item(2, "No id", ""), item(3, "<b>x</b>", "x"),
                                        item(2, "Long id", String(repeating: "i", count: 513))] as NSArray,
                            "current": "same"]
guard let toc = Heading.toc(result) else { fatalError("the outline did not decode") }
assert(toc.outline.map(\.level) == [1, 2, 4, 3] && toc.outline.map(\.anchor) == ["top", "same", "deep", "x"])
assert(toc.outline.map(\.id) == [0, 1, 2, 7])          // positions in the reported list
assert(toc.outline[3].text == "<b>x</b>")           // shown as text, never parsed
assert(toc.current == "same")
assert(Heading.toc(["outline": [] as NSArray, "current": ""] as NSDictionary).map { $0.outline.isEmpty && $0.current == nil } == true)
assert(Heading.toc(["outline": toc.outline.isEmpty, "current": "x"] as NSDictionary) == nil) // not an outline
assert(Heading.toc(nil) == nil && Heading.toc("mermaid") == nil)
assert(Heading.anchor("nowhere", in: toc.outline) == nil && Heading.anchor(42, in: toc.outline) == nil)
assert(Heading.anchor("top", in: toc.outline) == "top")
let many = NSArray(array: (0..<600).map { item(2, "h\($0)", "h\($0)") })
assert(Heading.outline(many)?.count == 500)
// The find list's results: {index, count, matches?} from midamFind, -Step and -Go.
let m = { (b: Any, h: Any, a: Any, p: Any) -> NSDictionary in ["before": b, "hit": h, "after": a, "path": p] }
let found: NSDictionary = ["index": NSNumber(value: 2.0), "count": 3,
                           "matches": [m("Run ", "make", " first", ["Setup", "Install"] as NSArray),
                                       m(42, "make", NSNull(), ["", 7, "Build"] as NSArray),
                                       m(String(repeating: "x", count: 300), "make", "", "not a path")] as NSArray]
guard let f = FindMatch.result(found), let list = f.matches else { fatalError("the find result did not decode") }
assert(f.index == 2 && f.count == 3 && list.map(\.id) == [0, 1, 2])
assert(list[0].before == "Run " && list[0].hit == "make" && list[0].after == " first" && list[0].path == ["Setup", "Install"])
assert(list[1].before == "" && list[1].after == "" && list[1].path == ["Build"]) // non-strings and empty headings dropped
assert(list[2].before.count == 200 && list[2].path.isEmpty)                      // bounded; a path that is no list is none
let step = FindMatch.result(["index": 0, "count": 0] as NSDictionary)
assert(step != nil && step!.index == 0 && step!.count == 0 && step!.matches == nil) // a step leaves the list alone
assert(FindMatch.result(["index": 4, "count": 3] as NSDictionary) == nil)          // past the last match
assert(FindMatch.result(["index": -1, "count": 3] as NSDictionary) == nil)
assert(FindMatch.result([1, 3] as NSArray) == nil && FindMatch.result(nil) == nil)  // not a result
let capped = NSArray(array: (0..<600).map { _ in m("", "a", "", [] as NSArray) })
assert(FindMatch.result(["index": 1, "count": 600, "matches": capped] as NSDictionary)?.matches?.count == 500)
print("toc rules: checks passed (outline, find list)")
