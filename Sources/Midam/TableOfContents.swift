import SwiftUI

/// The table of contents: a glass panel at the right, over the page (which never reflows for it).
/// The header's toggle and View > Show Table of Contents (⌘T) open and close it, for every tab,
/// remembered across launches (Store.tocOpen). While it is closed it shows itself once when a
/// tab's document is first shown, as a hint. Hidden for a document without headings and in 원문.
struct TableOfContents: View {
    @ObservedObject var store: Store
    let page: Page
    /// Where the panel starts: below the header, and below the find field while it shows.
    let top: CGFloat
    @State private var intro = false
    @State private var introStart = ContinuousClock.now
    @State private var onPanel = false
    @State private var leftAt: Double?
    @State private var hide: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 260
    private var available: Bool { page.tocAvailable }
    private var shown: Bool { TocIntro.shown(available: available, open: store.tocOpen, intro: intro) }

    var body: some View {
        panelArea
            .padding(.top, top)
            .padding(.trailing, 10) // under the header's right capsule
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: shown)
            .onChange(of: Intro(page: ObjectIdentifier(page), ready: available), initial: true) { introduce() }
            .onChange(of: store.tocOpen) { endIntro() } // the user's toggle takes over
    }

    /// Liquid Glass materializes on macOS 26; before that the material slides in a little and fades.
    /// Under Reduce Motion a plain fade (Reduce Transparency's opaque panel fades on 26 as well).
    @ViewBuilder private var panelArea: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                if shown { panel.glassEffectTransition(reduceMotion ? .identity : .materialize).transition(.opacity) }
            }
        } else if shown {
            panel.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 16)))
        }
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }
            }
            .onChange(of: page.tocCurrent, initial: true) { _, anchor in
                if let i = page.outline.first(where: { $0.anchor == anchor })?.id { proxy.scrollTo(i) }
            }
        }
        .glassPanel()
        .onHover { inside in
            onPanel = inside
            if !inside { leftAt = elapsed }
            if intro { scheduleHide() }
        }
        .onExitCommand { // Esc with focus in the panel
            endIntro()
            store.tocOpen = false
        }
        .onDisappear { onPanel = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table of Contents")
    }

    private var list: some View {
        let base = page.outline.map(\.level).min() ?? 1 // a document starting at h2 is not indented
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(page.outline) { h in
                TocRow(heading: h, indent: h.level - base, current: h.anchor == page.tocCurrent) { page.jump(to: h.anchor) }
                    .id(h.id)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
    }

    /// The one-time hint on a tab's first showing; not needed while the panel is open anyway.
    private func introduce() {
        guard available, !page.tocIntroduced else { return }
        let starts = TocIntro.starts(introduced: page.tocIntroduced, available: available, open: store.tocOpen)
        page.tocIntroduced = true
        guard starts else { return }
        intro = true
        introStart = .now
        leftAt = nil
        scheduleHide()
    }

    private var elapsed: Double {
        let d = ContinuousClock.now - introStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Ends the hint at TocIntro.end, rescheduled on every hover change. The deadline is always
    /// set (the cap while hovered), so a missing exit event cannot keep the panel up.
    private func scheduleHide() {
        hide?.cancel()
        let end = introStart + .seconds(TocIntro.end(hovered: onPanel, leftAt: leftAt))
        hide = Task {
            try? await Task.sleep(until: end, clock: .continuous)
            guard !Task.isCancelled else { return }
            intro = false
        }
    }

    private func endIntro() {
        hide?.cancel()
        intro = false
    }

    private struct Intro: Equatable {
        let page: ObjectIdentifier
        let ready: Bool
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
                .padding(.leading, 14 + CGFloat(indent) * 12)
                .padding(.trailing, 14)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// ☰ at the start of the header's right capsule: opens and closes the table of contents (the same
/// state as ⌘T). Ink while open; disabled without headings and in 원문.
struct TocToggle: View {
    @ObservedObject var store: Store
    let page: Page

    var body: some View {
        let on = store.tocOpen && page.tocAvailable
        StripIcon(label: "Table of Contents", tip: "Toggle Table of Contents", keys: [.tableOfContents], active: on,
                  enabled: page.tocAvailable, action: { store.tocOpen.toggle() }) {
            Image(systemName: "list.bullet.indent")
        }
        .accessibilityAddTraits(on ? [.isToggle, .isSelected] : .isToggle)
    }
}
