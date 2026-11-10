import SwiftUI

/// The table of contents, in the panel's Contents tab (⌥⌘T): the document's h1-h4 as an outline,
/// the section being read marked and kept in view. It never opens by itself when a document opens.
struct TocList: View {
    let page: Page

    var body: some View {
        if page.source {
            PanelHint(text: Text("Contents show in Reading view."))
        } else if page.outline.isEmpty {
            PanelHint(text: Text("This document has no headings."))
        } else {
            ScrollViewReader { proxy in
                ScrollView { list }
                    .onChange(of: page.tocCurrent, initial: true) { _, anchor in
                        if let i = page.outline.first(where: { $0.anchor == anchor })?.id { proxy.scrollTo(i) }
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table of Contents")
        }
    }

    private var list: some View {
        let base = page.outline.map(\.level).min() ?? 1 // a document starting at h2 is not indented
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(page.outline) { h in
                TocRow(heading: h, depth: h.level - base, current: h.anchor == page.tocCurrent) { page.jump(to: h.anchor) }
                    .id(h.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// One heading, as an outline in Xcode or Preview: the top level semibold, the next regular, deeper
/// ones smaller and faint, 12 pt further in per level, on one line (the whole title in the tooltip).
/// The section being read gets a thin accent bar at the left and ink.
private struct TocRow: View {
    let heading: Heading
    let depth: Int
    let current: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Text(verbatim: heading.text)
                .font(.system(size: depth < 2 ? 13 : 12, weight: depth == 0 ? .semibold : .regular))
                .foregroundStyle(GlassLabel.style(strong: depth < 2 || current, opaque: reduceTransparency))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.leading, 8 + CGFloat(depth) * 12)
                .padding(.trailing, 8)
                .background(Color.primary.opacity(hover ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .leading) {
                    if current { Capsule().fill(Color.accentColor).frame(width: 3, height: 14).padding(.leading, 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(Text(verbatim: heading.text))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
