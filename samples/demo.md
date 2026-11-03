# Midam Demo

A calm, read-only Markdown viewer. This file exercises every element v0 renders — **bold**, *italic*, ~~strikethrough~~, `inline code`, and a [link to example.com](https://example.com). Jump to [the table section](#tables).

## 한글 조판

미담은 마크다운 문서를 조용히 읽기 위한 뷰어입니다. 한글은 낱말 단위로 줄을 바꾸고, 아주 긴 주소는 https://example.com/a/very/long/path/that/should/still/break/nicely/when/the/window/is/narrow 처럼 필요한 곳에서 끊깁니다. “따옴표로 시작하는 문단”은 여백 밖으로 살짝 걸립니다.

## Lists

- Plain bullet item
- Another item with a nested list
  - Nested one
  - Nested two
- Last item

1. First ordered item
2. Second ordered item
3. Third ordered item

### Task list

- [x] Render GFM tables
- [x] Show task lists as disabled checkboxes
- [ ] Editing (coming later)

## Quote

> Simplicity is prerequisite for reliability.
>
> — Edsger W. Dijkstra

## Code

```swift
struct Greeting {
    let name: String
    func render() -> String { "Hello, \(name)!" }
}
```

```js
// Debounce: run fn once things go quiet.
export function debounce(fn, ms = 100) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}
```

```bash
#!/bin/sh
set -eu
for f in *.md; do
  echo "rendering $f"   # one file at a time
done
```

```
A fence without a language stays plain: no colours, no guessing.
```

## Links

- [Second sample](second.md) and [its Details section](second.md#details) open in Midam.
- [run.command](run.command) is a local script: Midam only reveals it in Finder, never runs it.
- [figure.svg](figure.svg) is revealed in Finder too.

## Tables

| Element     | Status | Notes                      |
|:------------|:------:|---------------------------:|
| Headings    | done   | h1 through h6              |
| Tables      | done   | alignment respected        |
| Task lists  | done   | read-only checkboxes       |

## Image

A relative image next to this file:

![Local figure](figure.svg)

---

## Hostile HTML (must do nothing)

<script>document.body.innerHTML = "SCRIPT RAN"</script>
<img src=x onerror="document.body.innerHTML = 'ONERROR RAN'">
<a href="javascript:document.body.innerHTML='JS LINK RAN'">javascript: link</a>
<iframe src="https://example.com"></iframe>

If you can read this paragraph, none of the lines above ran.

#### Fourth-level heading

Final paragraph with a footnote-free ending and a [mail link](mailto:hello@example.com).
