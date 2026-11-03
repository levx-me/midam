import AppKit
import SwiftUI

/// The header's tooltips: native ones take a second or more, these show after TipRules.delay
/// and then at once from control to control. One at a time, drawn by TipLayer over the window.
@MainActor final class Tips: ObservableObject {
    static let shared = Tips()
    nonisolated static let space = "reader" // ReaderView's coordinate space, where frames are measured

    struct Tip {
        let id: UUID
        let text: Text
        let anchor: CGRect
    }

    @Published private(set) var shown: Tip?
    private var pending: Task<Void, Never>?
    private var lastHidden: Double?
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private init() {
        // A click, a scroll or a key hides it (the event goes on untouched).
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { event in
            MainActor.assumeIsolated { Tips.shared.hide(cool: true) }
            return event
        }
    }

    func enter(_ id: UUID, _ text: Text, _ anchor: CGRect) {
        pending?.cancel()
        let tip = Tip(id: id, text: text, anchor: anchor)
        let wait = TipRules.wait(now: now, showing: shown != nil, lastHidden: lastHidden)
        if wait == 0 { shown = tip; return }
        pending = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            shown = tip
        }
    }

    func exit(_ id: UUID) {
        pending?.cancel()
        guard shown?.id == id else { return }
        hide(cool: false)
    }

    /// `cool`: a click, scroll or key ends tooltip mode as well.
    func hide(cool: Bool) {
        pending?.cancel()
        pending = nil
        if shown != nil { shown = nil; lastHidden = cool ? nil : now }
        if cool { lastHidden = nil }
    }
}

private struct FastTip: ViewModifier {
    let text: Text
    @State private var id = UUID()
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Tips.space)) } action: { frame = $0 }
            .onHover { inside in
                if inside { Tips.shared.enter(id, text, frame) } else { Tips.shared.exit(id) }
            }
            .onDisappear { Tips.shared.exit(id) }
    }
}

extension View {
    /// A fast tooltip under this header control. VoiceOver keeps the control's label and hint.
    func fastTip(_ text: Text) -> some View { modifier(FastTip(text: text)) }
}

/// Draws the one tooltip showing: a small glass label below its control, inside the window,
/// never taking clicks.
struct TipLayer: View {
    @ObservedObject private var tips = Tips.shared
    @State private var size = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { g in
            if let tip = tips.shown {
                let x = TipRules.x(mid: tip.anchor.midX, width: size.width, container: g.size.width)
                let y = TipRules.y(top: tip.anchor.minY, bottom: tip.anchor.maxY, height: size.height, container: g.size.height)
                tip.text
                    .font(.system(size: 11.5))
                    .foregroundStyle(GlassLabel.style(strong: true, opaque: reduceTransparency))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 7, style: .continuous)))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .opacity(size == .zero ? 0 : 1) // placed once measured
                    .offset(x: x, y: y)
                    .id(tip.id)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tips.shown?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
