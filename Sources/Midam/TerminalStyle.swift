import Foundation

/// The agent terminal's look from the Terminal settings, as plain values (no AppKit, no SwiftTerm)
/// so tools/TerminalStyleTest can check them. Terminal.swift reads it from the defaults and applies it.
struct TerminalStyle: Equatable {
    enum Cursor: String, CaseIterable { case block, bar, underline }

    var family = ""        // "" = the system monospaced font
    var size = 13.0        // points
    var spacing = 1.0      // line height multiplier (SwiftTerm's lineSpacing)
    var theme = TerminalTheme.system
    var cursor = Cursor.block
    var blink = true       // SwiftTerm's default cursor is a blinking block

    static let sizes: ClosedRange<Double> = 9...24
    static let spacings: ClosedRange<Double> = 1...1.6

    /// Stored values clamped to the settings' ranges; unknown names fall back to the defaults.
    init(family: String = "", size: Double = 13, spacing: Double = 1, theme: String = "", cursor: String = "", blink: Bool = true) {
        self.family = family
        self.size = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, size))
        self.spacing = min(Self.spacings.upperBound, max(Self.spacings.lowerBound, spacing))
        self.theme = TerminalTheme(rawValue: theme) ?? .system
        self.cursor = Cursor(rawValue: cursor) ?? .block
        self.blink = blink
    }

    /// SwiftTerm's CursorStyle tag name: blinkBlock, steadyBar, blinkUnderline…
    var cursorTag: String { (blink ? "blink" : "steady") + cursor.rawValue.capitalized }

    /// The space SwiftUI adds between lines for this line spacing, given the font's line height.
    func extraLeading(lineHeight: Double) -> Double { lineHeight * (spacing - 1) }
}

/// The terminal's colour themes: Follow Appearance keeps the system text colours (light or dark
/// with the window); the rest are fixed. ANSI colours are 16 sRGB values, 0xRRGGBB.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case system, light, dark, solarizedLight, solarizedDark, dracula

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: String(localized: "Follow Appearance")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        default: colors.name ?? rawValue
        }
    }

    /// Foreground and background; nil for Follow Appearance (the system's text colours).
    var fg: UInt32? { self == .system ? nil : colors.fg }
    var bg: UInt32? { self == .system ? nil : colors.bg }
    var ansi: [UInt32] { colors.ansi }

    private var colors: (name: String?, fg: UInt32, bg: UInt32, ansi: [UInt32]) {
        switch self {
        case .system, .light: (nil, 0x000000, 0xffffff, Self.terminalApp)
        case .dark: (nil, 0xe6e6e6, 0x1e1e1e, Self.terminalApp)
        case .solarizedLight: ("Solarized Light", 0x586e75, 0xfdf6e3, Self.solarized)
        case .solarizedDark: ("Solarized Dark", 0x93a1a1, 0x002b36, Self.solarized)
        case .dracula: ("Dracula", 0xf8f8f2, 0x282a36, Self.draculaANSI)
        }
    }

    /// SwiftTerm's default (Terminal.app's) palette.
    private static let terminalApp: [UInt32] = [
        0x000000, 0xc23621, 0x25bc24, 0xadad27, 0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
        0x818383, 0xfc391f, 0x31e722, 0xeaec23, 0x5833ff, 0xf935f8, 0x14f0f0, 0xe9ebeb,
    ]
    private static let solarized: [UInt32] = [
        0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
        0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
    ]
    private static let draculaANSI: [UInt32] = [
        0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
        0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
    ]
}
