import SwiftUI

// The right panel: find in the page, the table of contents and the keyboard shortcuts, one tab
// at a time (Store.panelOpen, Store.panelTab). Docked beside the page as the sidebar is on the
// left; floating over the page's right edge only when docking would leave the page too narrow.

enum PanelTab: String, CaseIterable {
    case find, toc, shortcuts

    var title: LocalizedStringKey {
        switch self {
        case .find: "Find"
        case .toc: "Contents"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .find: return "magnifyingglass"
        case .toc: return "list.bullet.indent"
        case .shortcuts: return "command"
        }
    }

    var keys: [KeyboardShortcut] {
        switch self {
        case .find: [.find, .findSlash]
        case .toc: [.tableOfContents]
        case .shortcuts: [.shortcuts]
        }
    }
}

/// The docked panel, an inspector beside the page: the sidebar's material and edge, a strip on the
/// header's line holding the panel button at the far right, then the panel. A strip at its left
/// edge resizes it (width remembered), as SidebarColumn's at the sidebar's right.
struct PanelColumn: View {
    @ObservedObject var store: Store
    @AppStorage(PanelColumn.widthKey) private var width = PanelColumn.defaultWidth
    @State private var start: Double?
    static let widthKey = "panelWidth", defaultWidth = 280.0
    static let widths = 240.0...420.0
    static func clamp(_ w: Double) -> Double { min(max(w, widths.lowerBound), widths.upperBound) }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea().frame(height: store.fullScreen ? 6 + TitleStrip.capsule + 6 : store.header)
                .overlay(alignment: .topTrailing) { // on the lights' line, clear of the drag gesture
                    PanelToggle(store: store)
                        .frame(height: TitleStrip.capsule)
                        .padding(.top, store.rowTop)
                        .padding(.trailing, 10)
                }
            PanelBody(store: store)
        }
        .frame(width: Self.clamp(width))
        .background { SidebarMaterial().ignoresSafeArea() }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 8)
                .offset(x: -4) // half over the page: ReaderView puts the column above it
                .contentShape(Rectangle())
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let from = start ?? Self.clamp(width)
                        start = from
                        width = Self.clamp(from - v.translation.width)
                    }
                    .onEnded { _ in start = nil })
                .accessibilityHidden(true)
        }
    }
}

/// The panel over the page's right edge, below the header, when the window is too narrow to dock
/// it: a glass panel (the header holds the panel button).
struct FloatingPanel: View {
    @ObservedObject var store: Store
    @AppStorage(PanelColumn.widthKey) private var width = PanelColumn.defaultWidth

    var body: some View {
        PanelBody(store: store)
            .padding(.top, 10)
            .frame(width: PanelColumn.clamp(width))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .glassPanel()
            .padding(.top, store.overlayTop)
            .padding(.trailing, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The panel itself: the tab switcher across its top, then the tab showing.
private struct PanelBody: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            PanelTabs(store: store)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            Group {
                if store.panelTab == .shortcuts { ShortcutsList() }
                else if let page = store.current?.page {
                    if store.panelTab == .find { FindTab(page: page).id(ObjectIdentifier(page)) } // each tab its own field
                    else { TocList(page: page) }
                } else {
                    PanelHint(text: Text("No Document Open"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel")
    }
}

/// The panel button: `sidebar.right`, the mirror of the sidebar's.
struct PanelToggle: View {
    @ObservedObject var store: Store

    var body: some View {
        StripIcon(label: store.panelOpen ? "Hide Panel" : "Show Panel", keys: [.panel],
                  action: { store.panelOpen.toggle() }) { // animated as from the keys, by ReaderView
            Image(systemName: "sidebar.right")
        }
    }
}

/// The tab switcher: the system's segmented control, icons only, across the panel's width (glass
/// on macOS 26 by itself). Each segment's name is its tooltip and its VoiceOver label.
private struct PanelTabs: View {
    @ObservedObject var store: Store

    var body: some View {
        Picker("Panel", selection: Binding(get: { store.panelTab }, set: { tab in
            store.panelTab = tab
            if tab == .find { store.current?.page.focusField() }
        })) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Image(systemName: tab.symbol)
                    .accessibilityLabel(tab.title)
                    .help(Text(tab.title) + Text(verbatim: " (\(tab.keys.map(\.glyph).joined(separator: ", ")))"))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

/// A calm line where a tab has nothing to show.
struct PanelHint: View {
    let text: Text
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        text
            .font(.system(size: 13))
            .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Find

/// The find field, where the current match is ("3 of 12", up and down), and every match listed: the line
/// around it with the match marked, under the headings it sits in. A row jumps there; ⌘G and ⇧⌘G
/// step, and the current row follows. Return and ⇧Return step too; Esc goes back to the page.
private struct FindTab: View {
    @Bindable var page: Page
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            field.padding(.horizontal, 10)
            if page.query.isEmpty {
                PanelHint(text: Text("Type to find in this document.") + Text(verbatim: "\n") + Text("Next") +
                          Text(verbatim: " \(KeyboardShortcut.findNext.glyph) · ") + Text("Previous") +
                          Text(verbatim: " \(KeyboardShortcut.findPrevious.glyph)"))
            } else if page.count == 0 {
                PanelHint(text: Text("No matches"))
            } else {
                status
                list
            }
        }
        .onChange(of: page.focusRequest) { focused = true }
        .onChange(of: focused) { Store.shared.findFocused = focused }
        .onDisappear { if focused { Store.shared.findFocused = false } }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in Document", text: $page.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { page.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1) }
                .onExitCommand { page.leaveField() }
                .onChange(of: page.query) { page.search() }
            if !page.query.isEmpty {
                Button { page.query = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .hairline), lineWidth: 1))
    }

    /// "3 of 12" and the steps; "first 500 listed" when the list stops short of every match.
    private var status: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(page.index) of \(page.count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(GlassLabel.style(strong: true, opaque: reduceTransparency))
                    .accessibilityLabel("\(page.index) of \(page.count) matches")
                if page.matches.count < page.count {
                    Text("First \(page.matches.count) listed")
                        .font(.system(size: 11))
                        .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                }
            }
            Spacer(minLength: 0)
            StripIcon(label: "Find Previous", keys: [.findPrevious], action: { page.step(-1) }) { Image(systemName: "chevron.up") }
            StripIcon(label: "Find Next", keys: [.findNext], action: { page.step(1) }) { Image(systemName: "chevron.down") }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(page.matches) { m in
                        FindRow(match: m, current: m.id == page.index - 1) { page.go(to: m) }.id(m.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .onChange(of: page.index, initial: true) { _, i in proxy.scrollTo(i - 1) } // the current row in view
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Matches")
    }
}

/// One match: the heading path small and faint above, the line with the match marked as macOS
/// marks found text (yellow, dark ink in either appearance). The current one on an accent tint.
private struct FindRow: View {
    let match: FindMatch
    let current: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var line: AttributedString {
        var hit = AttributedString(match.hit)
        hit.backgroundColor = Color(nsColor: .findHighlightColor)
        hit.foregroundColor = .black
        return AttributedString(match.before) + hit + AttributedString(match.after)
    }

    var body: some View {
        let path = match.path.joined(separator: " › ")
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                if !path.isEmpty {
                    Text(verbatim: path)
                        .font(.system(size: 11))
                        .foregroundStyle(GlassLabel.style(strong: false, opaque: reduceTransparency))
                        .lineLimit(1)
                        .truncationMode(.head) // the nearest heading matters most
                }
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(GlassLabel.style(strong: true, opaque: reduceTransparency))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(current ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hover ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(verbatim: match.before + match.hit + match.after))
        .accessibilityHint(Text(verbatim: path))
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
