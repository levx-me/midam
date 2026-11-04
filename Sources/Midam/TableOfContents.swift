import SwiftUI

/// The table of contents, in the panel's Contents tab (⌥⌘T): the document's h1-h3, the section
/// being read in ink and kept in view. It never opens by itself when a document opens.
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
                TocRow(heading: h, indent: h.level - base, current: h.anchor == page.tocCurrent) { page.jump(to: h.anchor) }
                    .id(h.id)
            }
        }
        .padding(.bottom, 10)
    }
}

/// One heading: plain text, indented by level; the section being read in ink, the others faint
/// (the header labels' styles, so contrast holds the same way on the glass).
private struct TocRow: View {
    let heading: Heading
    let indent: Int
    let current: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Text(verbatim: heading.text)
                .font(.system(size: 13, weight: current ? .medium : .regular))
                .foregroundStyle(GlassLabel.style(strong: current || hover, opaque: reduceTransparency))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16 + CGFloat(indent) * 12)
                .padding(.trailing, 14)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
