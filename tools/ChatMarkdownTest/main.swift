// Run: swiftc -swift-version 6 Sources/Midam/ChatMarkdown.swift tools/ChatMarkdownTest/main.swift -o /tmp/chatmd && /tmp/chatmd
import Foundation

let md = """
# Plan
Some **bold** text
on two lines.

- one
  - nested
2. second
> quoted
> more
---
```swift
let x = 1
```
| a | b |
|---|---|
after
"""
let b = ChatMarkdown.blocks(md)
assert(b == [
    .heading(level: 1, text: "Plan"),
    .paragraph("Some **bold** text\non two lines."),
    .item(text: "one", marker: nil, indent: 0),
    .item(text: "nested", marker: nil, indent: 1),
    .item(text: "second", marker: "2.", indent: 0),
    .quote("quoted\nmore"),
    .rule,
    .code("let x = 1"),
    .code("| a | b |\n|---|---|"),
    .paragraph("after"),
], "\(b)")
// A fence still streaming in shows as code.
assert(ChatMarkdown.blocks("Look:\n```\nhalf") == [.paragraph("Look:"), .code("half")])
assert(ChatMarkdown.blocks("") == [])
// Tabs restore from what was saved.
let saved = [AgentTabSave(session: "abc", project: "/p"), AgentTabSave(session: nil, project: "/q", terminal: true)]
let back = try! JSONDecoder().decode([AgentTabSave].self, from: JSONEncoder().encode(saved))
assert(back == saved)
print("chat markdown: 4 checks passed")
