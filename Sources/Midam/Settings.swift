import AppKit
import SwiftUI

// Reading settings: one global set in UserDefaults, applied live to every document.
// Defaults: system font, 16-18 px, line height 2.05, 36em (the 보통 presets).

enum Pref {
    static let font = "bodyFont"       // font family name, "" = system
    static let codeFont = "codeFont"   // monospaced family name, "" = system monospaced
    static let size = "textSize"       // multiplier on the responsive 16-18 px body size
    static let tracking = "letterSpacingPreset"     // Spacing preset index (0, 1, 2)
    static let leading = "lineHeightPreset"
    static let paragraph = "paragraphSpacingPreset"
    static let measure = "columnWidthPreset"
    static let theme = "theme"            // Theme raw value: the appearance (모양), not a colour theme
    static let lightTheme = "lightColorTheme" // ColorTheme id for the light appearance
    static let darkTheme = "darkColorTheme"   // ColorTheme id for the dark appearance
    static let all = [font, codeFont, size, tracking, leading, paragraph, measure, theme, lightTheme, darkTheme]

    @MainActor static func reset() {
        for k in all { UserDefaults.standard.removeObject(forKey: k) }
        Theme.apply(Theme.system.rawValue)
        ThemeDraft.shared.discard()
    }
}

/// 글자 크기: a slider in Settings, ⌘+ / ⌘− / ⌘0 in the menu.
struct Knob {
    let key: String
    let label: LocalizedStringKey
    let initial: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    func clamp(_ v: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
    }

    static var size: Knob {
        Knob(key: Pref.size, label: "Text Size", initial: 1, range: 0.7...2, step: 0.05,
             format: { "\(Int(($0 * 100).rounded()))%" })
    }
}

/// The spacing settings: each a choice of three presets, stored as the preset's index.
struct Spacing {
    let key: String
    let legacyKey: String // the free numeric value earlier versions stored
    let label: LocalizedStringKey
    let names: [LocalizedStringKey]
    let values: [Double]
    static let normal = 1

    func value(_ i: Int) -> Double { values[min(max(i, 0), values.count - 1)] }
    func nearest(_ v: Double) -> Int { values.indices.min { abs(values[$0] - v) < abs(values[$1] - v) } ?? Self.normal }

    static var tracking: Spacing {
        Spacing(key: Pref.tracking, legacyKey: "letterSpacing", label: "Letter Spacing",
                names: ["Narrow", "Normal", "Wide"], values: [-0.01, 0, 0.03]) // em
    }
    static var leading: Spacing {
        Spacing(key: Pref.leading, legacyKey: "lineHeight", label: "Line Spacing",
                names: ["Tight", "Normal", "Loose"], values: [1.75, 2.05, 2.35]) // 보통 (the default) was 1.75
    }
    static var paragraph: Spacing {
        Spacing(key: Pref.paragraph, legacyKey: "paragraphSpacing", label: "Paragraph Spacing",
                names: ["Tight", "Normal", "Loose"], values: [0.75, 1.15, 1.6]) // em
    }
    static var measure: Spacing {
        Spacing(key: Pref.measure, legacyKey: "columnWidth", label: "Column Width",
                names: ["Narrow", "Normal", "Wide"], values: [30, 36, 46]) // em
    }

    /// An old numeric value lands on its nearest preset, once; the old key is then dropped.
    static func migrate() {
        let d = UserDefaults.standard
        for s in [tracking, leading, paragraph, measure] where d.object(forKey: s.legacyKey) != nil {
            if d.object(forKey: s.key) == nil { d.set(s.nearest(d.double(forKey: s.legacyKey)), forKey: s.key) }
            d.removeObject(forKey: s.legacyKey)
        }
    }
}

/// The appearance (모양): System, Light or Dark. It picks which colour theme the page wears.
enum Theme: String, CaseIterable {
    case system, light, dark

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Overrides the app appearance; the web view, paper colour and all chrome follow it.
    @MainActor static func apply(_ raw: String) {
        NSApp.appearance = switch Theme(rawValue: raw) ?? .system {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// A colour theme for the page (document content only; the window chrome, controls and accent
/// stay Midam's). One light and one dark theme are chosen; the appearance decides which applies.
/// The table is Resources/themes.json, with sources and licences in Resources/THEMES.md.
struct ColorTheme: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Midam's own: monochrome, so keywords are told apart by weight.
    let mono: Bool
    let colors: [String: String]

    static let midam = "midam"

    private struct Table: Decodable { let light: [ColorTheme]; let dark: [ColorTheme] }

    private static let table: Table = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let t = try? JSONDecoder().decode(Table.self, from: data), !t.light.isEmpty, !t.dark.isEmpty
        else { fatalError("Missing or invalid themes.json in Contents/Resources; run ./build.sh") }
        return Table(light: t.light.map(\.checked), dark: t.dark.map(\.checked))
    }()

    static func all(dark: Bool) -> [ColorTheme] { dark ? table.dark : table.light }

    /// The theme with this id, or Midam (listed first) for an unknown one.
    static func named(_ id: String, dark: Bool) -> ColorTheme {
        all(dark: dark).first { $0.id == id } ?? all(dark: dark)[0]
    }

    /// Keeps only token names render.js accepts with #rrggbb values (render.js checks again).
    private var checked: ColorTheme {
        ColorTheme(id: id, name: name, mono: mono, colors: colors.filter {
            $0.key.range(of: "^[a-z]+(-[a-z]+)*$", options: .regularExpression) != nil
                && $0.value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
        })
    }

    /// Merged into the midamStyle() arguments.
    var arguments: [String: Any] { ["colors": colors, "monochrome": mono] }

    func color(_ token: String) -> NSColor {
        let v = colors[token].flatMap { UInt32($0.dropFirst(), radix: 16) } ?? 0x808080
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// The picker's swatch: the page background with heading, link, string and comment dots.
    var swatch: NSImage {
        let ground = color("bg"), dots = ["heading", "link", "tk-string", "tk-comment"].map(color)
        let image = NSImage(size: NSSize(width: 34, height: 16), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            ground.setFill()
            card.fill()
            NSColor.separatorColor.setStroke() // drawn per appearance, so the edge suits the menu
            card.stroke()
            for (i, dot) in dots.enumerated() {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5 + CGFloat(i) * 6.5, y: 5.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.accessibilityDescription = name
        return image
    }
}

/// What the page needs from the settings, passed to render.js as arguments.
struct Reading: Equatable {
    var font: String
    var mono: String
    var size: Double
    var tracking: Double
    var leading: Double
    var paragraph: Double
    var measure: Double
    /// The window header's height in points; the page runs under it with this much top padding.
    var header: Double

    /// Font names are passed only if they are installed or bundled families (render.js also
    /// quotes them as CSS strings); numbers are clamped again in render.js. The bundled faces
    /// go along as @font-face sources, since the page renders in WebKit's own process.
    var arguments: [String: Any] {
        ["font": Fonts.isInstalled(font) ? font : "", "mono": Fonts.isInstalled(mono) ? mono : "",
         "size": size, "tracking": tracking, "leading": leading, "paragraph": paragraph, "measure": measure,
         "header": header, "faces": BundledFonts.arguments]
    }
}

enum Fonts {
    /// Every visible installed or bundled family with its localized name (e.g. AppleMyungjo, 애플명조),
    /// sorted for display. CoreText only (thread-safe): AppDelegate builds it off the main thread
    /// after launch, so Settings opens without listing some 250 families first.
    /// ponytail: listed once per launch; a font installed while Midam runs shows after a relaunch.
    static let all: [(family: String, name: String)] = {
        installed.union(BundledFonts.families).filter { !$0.hasPrefix(".") }.sorted()
            .map { family in
                let d = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
                return (family, CTFontDescriptorCopyLocalizedAttribute(d, kCTFontFamilyNameAttribute, nil) as? String ?? family)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }()

    /// The installed families (the same set as NSFontManager's), read once with CoreText: thread-safe,
    /// and about 20 ms instead of 100-200 ms for NSFontManager's first list.
    /// ponytail: once per launch, like Fonts.all; a font installed while Midam runs counts after a relaunch.
    static let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])

    static func isInstalled(_ family: String) -> Bool {
        BundledFonts.families.contains(family) || installed.contains(family)
    }

    /// Installed fixed-pitch families, matched by descriptor (no fonts are loaded), and the bundled ones.
    static let monospaced: [String] = {
        let traits = [NSFontDescriptor.TraitKey.symbolic: NSNumber(value: NSFontDescriptor.SymbolicTraits.monoSpace.rawValue)]
        let found = NSFontDescriptor(fontAttributes: [.traits: traits])
            .matchingFontDescriptors(withMandatoryKeys: [.traits])
            .compactMap { $0.object(forKey: .family) as? String }
        return Set(found).union(BundledFonts.monospaced).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// The menu's short list: coding fonts, leaving out CJK fonts that merely report fixed pitch.
    static let codingFonts: [String] = monospaced.filter {
        $0.range(of: "mono|code|menlo|monaco|courier|consol|hack|iosevka|d2coding|inconsolata",
                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func ns(_ family: String, size: CGFloat) -> NSFont {
        if let face = BundledFonts.regular[family] { return NSFont(descriptor: face, size: size) ?? .systemFont(ofSize: size) }
        return (family.isEmpty ? nil : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size))
            ?? .systemFont(ofSize: size)
    }

    static func displayName(_ family: String) -> String {
        family.isEmpty ? String(localized: "System Font") : NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }
}

/// The fonts shipped in Resources/Fonts (WOFF2; licences and sources in Resources/Fonts/LICENSES
/// and README.md). The page, in WebKit's own process, gets them as @font-face rules from render.js;
/// the native lists draw each family's regular face straight from its file. They are not
/// registered with the process: registering these WOFF2 files took about 1 s at launch and made
/// every later family query decode them again (about 1 s more when Settings first listed fonts).
enum BundledFonts {
    struct Face: Sendable {
        let file: String, family: String, weight: String, italic: Bool, mono: Bool
        init(_ file: String, _ family: String, _ weight: String = "100 900", italic: Bool = false, mono: Bool = false) {
            (self.file, self.family, self.weight, self.italic, self.mono) = (file, family, weight, italic, mono)
        }
    }

    static let faces: [Face] = [
        Face("PretendardVariable", "Pretendard Variable"),
        Face("Literata", "Literata"), Face("Literata-Italic", "Literata", italic: true),
        Face("SourceSerif4", "Source Serif 4 Variable"), Face("SourceSerif4-Italic", "Source Serif 4 Variable", italic: true),
        Face("iAWriterQuattroV", "iA Writer Quattro V"), Face("iAWriterQuattroV-Italic", "iA Writer Quattro V", italic: true),
        Face("Geist", "Geist"), Face("Geist-Italic", "Geist", italic: true),
        Face("PlusJakartaSans", "Plus Jakarta Sans"), Face("PlusJakartaSans-Italic", "Plus Jakarta Sans", italic: true),
        Face("JetBrainsMono", "JetBrains Mono", mono: true), Face("JetBrainsMono-Italic", "JetBrains Mono", italic: true, mono: true),
        Face("GeistMono", "Geist Mono", mono: true), Face("GeistMono-Italic", "Geist Mono", italic: true, mono: true),
        Face("D2Coding", "D2Coding", "400", mono: true), Face("D2Coding-Bold", "D2Coding", "700", mono: true),
    ]

    static let families = Set(faces.map(\.family))
    static let monospaced = Set(faces.filter(\.mono).map(\.family))

    /// Each family's upright regular face (weight nearest 0, the first such named instance), read
    /// from its first upright file: what NSFontManager picked for these families when registered.
    /// Immutable CoreText descriptors, safe on any thread; AppDelegate reads them off the main thread.
    nonisolated(unsafe) static let regular: [String: NSFontDescriptor] = {
        var out: [String: NSFontDescriptor] = [:]
        for f in faces where !f.italic && out[f.family] == nil {
            guard let url = url(f) else { NSLog("Midam: missing Fonts/\(f.file).woff2; run ./build.sh"); continue }
            guard let all = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
            let weight = { (d: CTFontDescriptor) -> Double in
                abs((CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontWeightTrait] as? Double ?? 0)
            }
            if let d = all.min(by: { weight($0) < weight($1) }) { out[f.family] = d as NSFontDescriptor }
        }
        return out
    }()

    private static func url(_ face: Face) -> URL? {
        Bundle.main.url(forResource: face.file, withExtension: "woff2", subdirectory: "Fonts")
    }

    /// For render.js: one @font-face per bundled file, served by FontSchemeHandler as
    /// midam-font:///<file>.woff2 (no bundle path reaches the page).
    static var arguments: [[String: String]] {
        faces.filter { url($0) != nil }.map { f in
            ["family": f.family, "url": "\(FontSchemeHandler.scheme):///\(f.file).woff2", "weight": f.weight,
             "style": f.italic ? "italic" : "normal"]
        }
    }
}

/// The curated fonts shown first in Settings › 글꼴: bundled ones (Built-in), then reading faces
/// installed on this Mac. Each candidate lists alternative family names; the first installed one
/// is shown. "" is the system font (SF Pro / SF Mono), always there.
enum RecommendedFonts {
    struct Pick: Sendable { let family: String; let hint: String; let builtIn: Bool }
    private struct Candidate: Sendable {
        let names: [String], hint: String, builtIn: Bool
        init(_ names: String..., hint: String, builtIn: Bool = false) { (self.names, self.hint, self.builtIn) = (names, hint, builtIn) }
    }

    private static let bodyCandidates = [
        Candidate("Pretendard Variable", hint: "Korean sans with Inter-based Latin", builtIn: true),
        Candidate("Literata", hint: "Serif made for screens", builtIn: true),
        Candidate("Source Serif 4 Variable", hint: "Book-like serif", builtIn: true),
        Candidate("iA Writer Quattro V", hint: "Calm face from a writing app", builtIn: true),
        Candidate("Geist", hint: "Clean Latin sans", builtIn: true),
        Candidate("Plus Jakarta Sans", hint: "Friendly Latin sans", builtIn: true),
        Candidate("", hint: "System default"),
        Candidate("Apple SD Gothic Neo", hint: "Korean sans for body text"),
        Candidate("AppleMyungjo", hint: "Korean serif for long reading"),
        Candidate("MaruBuri", hint: "Korean serif for long reading"),
        Candidate("Noto Sans KR", hint: "Korean sans for body text"),
        Candidate("Noto Serif KR", hint: "Korean serif for long reading"),
        Candidate("NanumBarunGothic", "Nanum Gothic", "NanumGothic", hint: "Korean sans for body text"),
        Candidate("Nanum Myeongjo", "NanumMyeongjo", hint: "Korean serif for long reading"),
        Candidate("SUIT", "SUIT Variable", hint: "Korean sans for body text"),
        Candidate("Spoqa Han Sans Neo", hint: "Korean sans for body text"),
        Candidate("New York", hint: "Book-like serif"),
        Candidate("Charter", hint: "Book-like serif"),
        Candidate("Iowan Old Style", hint: "Book-like serif"),
        Candidate("Georgia", hint: "Serif made for screens"),
        Candidate("Palatino", hint: "Book-like serif"),
        Candidate("Avenir Next", hint: "Clean Latin sans"),
    ]

    private static let codeCandidates = [
        Candidate("JetBrains Mono", hint: "Made for code", builtIn: true),
        Candidate("Geist Mono", hint: "Clean Latin mono", builtIn: true),
        Candidate("D2Coding", hint: "Korean coding font", builtIn: true),
        Candidate("", hint: "System default"),
        Candidate("Fira Code", hint: "With ligatures"),
        Candidate("IBM Plex Mono", hint: "Made for code"),
        Candidate("Cascadia Code", hint: "With ligatures"),
        Candidate("Menlo", hint: "Classic Mac monospace"),
        Candidate("Monaco", hint: "Classic Mac monospace"),
    ]

    /// Read once.
    /// ponytail: a font installed while Midam runs shows after a relaunch, like Fonts.all.
    static let body = installed(bodyCandidates)
    static let code = installed(codeCandidates)

    private static func installed(_ candidates: [Candidate]) -> [Pick] {
        var seen = Set<String>()
        return candidates.compactMap { c in
            guard let f = c.names.first(where: { $0.isEmpty || Fonts.isInstalled($0) }), seen.insert(f).inserted else { return nil }
            return Pick(family: f, hint: c.hint, builtIn: c.builtIn)
        }
    }
}

/// Asks the settings window to show the font list with the search field focused.
@MainActor @Observable final class SettingsRoute {
    static let shared = SettingsRoute()
    var focusFontSearch = false

    static let tabKey = "settingsTab"

    static func showFonts() {
        UserDefaults.standard.set(SettingsView.Tab.fonts.rawValue, forKey: tabKey)
        shared.focusFontSearch = true
        open()
    }

    /// Opens the Settings scene through its own app-menu item (⌘,). The reader window is
    /// AppKit-hosted, outside any SwiftUI scene, where the openSettings action is not reliable.
    static func open() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        menu.performActionForItem(at: i)
    }
}

/// The three presets of a spacing setting: a checkmarked submenu in the menu bar, a segmented
/// control in Settings.
struct PresetPicker: View {
    let spacing: Spacing
    @Binding var index: Int

    var body: some View {
        Picker(spacing.label, selection: $index) {
            ForEach(spacing.names.indices, id: \.self) { Text(spacing.names[$0]).tag($0) }
        }
    }
}

/// 모양: System, Light or Dark.
struct AppearancePicker: View {
    @Binding var theme: String

    var body: some View {
        Picker("Appearance", selection: Binding<Theme?>(get: { Theme(rawValue: theme) ?? .system }, set: {
            if let t = $0 { theme = t.rawValue; Theme.apply(t.rawValue) } // also with no document open
        })) {
            ForEach(Theme.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
    }
}

/// 라이트 테마 / 다크 테마: a pop-up of that appearance's colour themes, each with its swatch.
/// The page follows at once; an unknown stored id shows (and applies) as Midam.
struct ColorThemePicker: View {
    let label: LocalizedStringKey
    let dark: Bool
    @Binding var id: String

    var body: some View {
        Picker(label, selection: Binding(get: { ColorTheme.named(id, dark: dark).id }, set: { id = $0 })) {
            ForEach(ColorTheme.all(dark: dark)) { t in
                Label { Text(verbatim: t.name) } icon: { Image(nsImage: t.swatch) }.tag(t.id)
            }
        }
    }
}

// MARK: Theme tab

/// The Theme tab's pending choice; nil means "as applied". Only Apply writes the defaults (and
/// so re-styles the open documents); Revert, Reset to Defaults or closing Settings drops it.
@MainActor @Observable final class ThemeDraft {
    static let shared = ThemeDraft()
    var light: String?
    var dark: String?
    /// Which pending theme the preview shows: the list last touched; nil follows the appearance.
    var previewDark: Bool?

    func discard() { light = nil; dark = nil; previewDark = nil }
}

struct ThemeSettings: View {
    @AppStorage(Pref.theme) private var appearance = Theme.system.rawValue
    @AppStorage(Pref.lightTheme) private var lightTheme = ColorTheme.midam
    @AppStorage(Pref.darkTheme) private var darkTheme = ColorTheme.midam
    @Environment(\.colorScheme) private var scheme
    private let draft = ThemeDraft.shared

    private var pendingLight: String { ColorTheme.named(draft.light ?? lightTheme, dark: false).id }
    private var pendingDark: String { ColorTheme.named(draft.dark ?? darkTheme, dark: true).id }
    private var changed: Bool {
        pendingLight != ColorTheme.named(lightTheme, dark: false).id || pendingDark != ColorTheme.named(darkTheme, dark: true).id
    }
    private var previewDark: Bool { draft.previewDark ?? (scheme == .dark) }

    var body: some View {
        Form {
            Section {
                AppearancePicker(theme: $appearance).pickerStyle(.segmented)
            } footer: {
                Text("Appearance applies at once and decides which theme the page wears.")
                    .foregroundStyle(Color(nsColor: .muted))
            }
            Section {
                ColorThemePicker(label: "Light Theme", dark: false,
                                 id: Binding(get: { pendingLight }, set: { draft.light = $0; draft.previewDark = false }))
                ColorThemePicker(label: "Dark Theme", dark: true,
                                 id: Binding(get: { pendingDark }, set: { draft.dark = $0; draft.previewDark = true }))
                Picker("Preview", selection: Binding(get: { previewDark }, set: { draft.previewDark = $0 })) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                ThemePreview(theme: ColorTheme.named(previewDark ? pendingDark : pendingLight, dark: previewDark))
            }
            HStack {
                if changed { Text("Not applied yet").foregroundStyle(Color(nsColor: .muted)) }
                Spacer()
                Button("Revert") { draft.light = nil; draft.dark = nil }
                    .actionButton()
                    .disabled(!changed)
                Button("Apply") {
                    lightTheme = pendingLight
                    darkTheme = pendingDark
                    draft.light = nil
                    draft.dark = nil
                    AccessibilityNotification.Announcement(String(localized: "Theme applied")).post()
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A short sample page in a theme, drawn natively from the same tokens and the same element
/// mapping as the page (heading, link with its thin underline, inline code on its tint, list
/// marker, quote with its edge, a code block with its softened edge and code tokens).
struct ThemePreview: View {
    let theme: ColorTheme

    private func c(_ token: String) -> Color { Color(nsColor: theme.color(token)) }

    private func run(_ s: String, _ token: String, code: Bool = false, weight: Font.Weight = .regular,
                     italic: Bool = false) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = c(token)
        let f: Font = code ? .system(size: 11.5, weight: weight, design: .monospaced) : .system(size: 13, weight: weight)
        a.font = italic ? f.italic() : f
        return a
    }

    var body: some View {
        let kw: Font.Weight = theme.mono ? .semibold : .regular
        var link = run(String(localized: "a link"), "link")
        link.underlineStyle = Text.LineStyle(pattern: .solid, color: c("link").opacity(0.4))
        var code = run("code()", "code", code: true)
        code.backgroundColor = c("code-bg")
        let space = run(" ", "text")
        return VStack(alignment: .leading, spacing: 9) {
            Text(String(localized: "Morning Notes"))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(c("heading"))
            Text(run(String(localized: "Plain text,"), "text") + space + link + space + run(String(localized: "and"), "text") + space + code)
            VStack(alignment: .leading, spacing: 3) {
                ForEach([String(localized: "First item"), String(localized: "Second item")], id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").foregroundStyle(c("marker"))
                        Text(item).foregroundStyle(c("text"))
                    }
                    .font(.system(size: 13))
                }
            }
            HStack(spacing: 10) {
                Rectangle().fill(c("quote")).frame(width: 2)
                Text(String(localized: "A quoted line")).font(.system(size: 13)).foregroundStyle(c("quote"))
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(run("// note", "tk-comment", code: true, italic: true))
                Text(run("let", "tk-keyword", code: true, weight: kw) + run(" greeting = ", "text", code: true)
                     + run("\"hello\"", "tk-string", code: true))
                Text(run("func", "tk-keyword", code: true, weight: kw) + run(" ", "text", code: true)
                     + run("greet", "tk-title", code: true) + run("(times: ", "text", code: true)
                     + run("Int", "tk-type", code: true) + run(" = ", "text", code: true)
                     + run("3", "tk-number", code: true) + run(")", "text", code: true))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c("code-bg"))
            .overlay(alignment: .leading) { Rectangle().fill(c("code").opacity(0.45)).frame(width: 2) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c("bg"), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview"))
        .accessibilityValue(Text(verbatim: theme.name))
    }
}

// MARK: Format menu

@MainActor struct FormatMenu: Commands {
    @AppStorage(Pref.codeFont) private var codeFont = ""
    @AppStorage(Pref.size) private var size = Knob.size.initial
    @AppStorage(Pref.tracking) private var tracking = Spacing.normal
    @AppStorage(Pref.leading) private var leading = Spacing.normal
    @AppStorage(Pref.paragraph) private var paragraph = Spacing.normal
    @AppStorage(Pref.measure) private var measure = Spacing.normal
    @AppStorage(Pref.theme) private var theme = Theme.system.rawValue

    var body: some Commands {
        CommandMenu("Format") {
            Button("Choose Font…") { SettingsRoute.showFonts() }
            Divider()
            Button("Bigger") { size = Knob.size.clamp(size + 0.1) }
                .keyboardShortcut(.bigger).disabled(size >= Knob.size.range.upperBound)
            Button("Smaller") { size = Knob.size.clamp(size - 0.1) }
                .keyboardShortcut(.smaller).disabled(size <= Knob.size.range.lowerBound)
            Button("Default Size") { size = Knob.size.initial }
                .keyboardShortcut(.defaultSize).disabled(size == Knob.size.initial)
            Divider()
            PresetPicker(spacing: .tracking, index: $tracking)
            PresetPicker(spacing: .leading, index: $leading)
            PresetPicker(spacing: .paragraph, index: $paragraph)
            PresetPicker(spacing: .measure, index: $measure)
            Divider()
            AppearancePicker(theme: $theme)
            Menu("Code Font") {
                Picker("Code Font", selection: $codeFont) {
                    Text("System Monospaced").tag("")
                    ForEach(Fonts.codingFonts, id: \.self) { Text(verbatim: $0).tag($0) }
                    if !codeFont.isEmpty, !Fonts.codingFonts.contains(codeFont) {
                        Text(verbatim: codeFont).tag(codeFont) // chosen in Settings from the full list
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Choose in Settings…") { SettingsRoute.showFonts() }
            }
            Divider()
            Button("Reset to Defaults") { Pref.reset() }
        }
    }
}

// MARK: Settings window

struct SettingsView: View {
    enum Tab: String { case general, theme, fonts }
    @AppStorage(SettingsRoute.tabKey) private var tab = Tab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general.rawValue)
            ThemeSettings()
                .tabItem { Label("Theme", systemImage: "paintpalette") }
                .tag(Tab.theme.rawValue)
            FontSettings()
                .tabItem { Label("Fonts", systemImage: "textformat") }
                .tag(Tab.fonts.rawValue)
        }
        .frame(width: 480)
        .tint(Color.accentColor)
        .background(FullScreenAuxiliary())
    }
}

/// Lets the Settings window join a full-screen Space instead of switching to another desktop.
/// Set as the view enters its window, before the window is first ordered front. It also drops
/// an unapplied theme choice when the window closes.
struct FullScreenAuxiliary: NSViewRepresentable {
    final class Probe: NSView {
        private var closing: Any?

        override func viewWillMove(toWindow window: NSWindow?) {
            super.viewWillMove(toWindow: window)
            window?.collectionBehavior.insert(.fullScreenAuxiliary)
            if let closing { NotificationCenter.default.removeObserver(closing) }
            closing = window.map {
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: $0, queue: .main) { _ in
                    MainActor.assumeIsolated { ThemeDraft.shared.discard() }
                }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The app's language, kept in the app-domain AppleLanguages default: the same setting as
/// System Settings › General › Language & Region › Applications, so the two always agree.
enum AppLanguage: String, CaseIterable {
    case system, en, ko

    static let key = "AppleLanguages"
    /// The language this run started with; menus and AppKit chrome change only on relaunch.
    static let atLaunch = current

    static var current: AppLanguage {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
        return own?.first.flatMap { code in allCases.first { $0 != .system && code.hasPrefix($0.rawValue) } } ?? .system
    }

    func save() {
        if self == .system { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set([rawValue], forKey: Self.key) }
    }

    /// Quits, then opens Midam again once this process has exited; the restore brings the tabs back.
    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Paths and pid go in as arguments, never into the script text.
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"", "sh",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try p.run() } catch { NSApp.presentError(error); return }
        NSApp.terminate(nil)
    }
}

struct LanguageSection: View {
    @State private var language = AppLanguage.current

    var body: some View {
        Section {
            Picker("Language", selection: $language) {
                Text("System").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.en) // each language in its own name
                Text(verbatim: "한국어").tag(AppLanguage.ko)
            }
            .onChange(of: language) { language.save() }
            if language != AppLanguage.atLaunch {
                HStack {
                    Text("Applies after restart").foregroundStyle(Color(nsColor: .muted))
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                        .primaryButton()
                }
                // In the newly chosen language where there is one.
                .environment(\.locale, language == .system ? .current : Locale(identifier: language.rawValue))
            }
        }
    }
}

/// Projects hidden from the sidebar (its ⋯ menu), each with a way back.
struct HiddenProjectsSection: View {
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        Section("Hidden Projects") {
            if library.hidden.isEmpty {
                Text("Projects you hide from the sidebar appear here.").foregroundStyle(Color(nsColor: .muted))
            } else {
                ForEach(library.hidden.sorted(), id: \.self) { id in
                    let name = (id as NSString).lastPathComponent
                    LabeledContent {
                        Button("Show in Sidebar") { library.unhide(id) }
                            .actionButton()
                            .accessibilityLabel(Text(verbatim: String(format: String(localized: "Show %@ in Sidebar"), name)))
                    } label: {
                        Text(verbatim: name)
                        Text(verbatim: (id as NSString).abbreviatingWithTildeInPath)
                    }
                }
            }
        }
    }
}

/// The render cache (RenderCache): its size, and a way to empty it.
struct CacheSection: View {
    @State private var size: Int?

    var body: some View {
        Section {
            LabeledContent("Cache") {
                HStack(spacing: 10) {
                    Text(verbatim: size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                        .foregroundStyle(Color(nsColor: .muted))
                        .monospacedDigit()
                    Button("Clear Cache") {
                        RenderCache.clear()
                        size = 0
                    }
                    .actionButton()
                    .disabled(size == 0)
                }
            }
        }
        .task { size = await Task.detached(priority: .utility) { RenderCache.size() }.value }
    }
}

/// Install `midam` (V6): a link in ~/.local/bin to the script in the app (CLIInstaller), no admin
/// rights. Says where it went, and the line to add when that folder is not on the login PATH.
struct CommandLineSection: View {
    @State private var result: String?
    @State private var offPath = false
    @State private var working = false

    var body: some View {
        Section {
            LabeledContent {
                Button("Install") { install() }
                    .actionButton()
                    .disabled(working)
            } label: {
                Text("Command Line Tool")
                Text("Lets agents open documents and wait for your reply: midam open, midam review.")
            }
            if let result {
                Text(verbatim: result)
                    .foregroundStyle(Color(nsColor: .muted))
                    .textSelection(.enabled)
            }
            if offPath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("~/.local/bin is not on your PATH. Add this line to ~/.zshrc:")
                    Text(verbatim: #"export PATH="$HOME/.local/bin:$PATH""#)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func install() {
        working = true
        Task {
            // Off the main thread: it asks the login shell for PATH (up to 3 s).
            let done = await Task.detached(priority: .userInitiated) { () -> Result<(link: URL, onPath: Bool), CLIInstallError> in
                do { return .success(try CLIInstaller.install()) }
                catch let e as CLIInstallError { return .failure(e) }
                catch { return .failure(.failed(error.localizedDescription)) }
            }.value
            working = false
            switch done {
            case .success(let r):
                result = String(format: String(localized: "Installed: %@"), (r.link.path as NSString).abbreviatingWithTildeInPath)
                offPath = !r.onPath
            case .failure(.occupied):
                result = String(localized: "~/.local/bin/midam already exists and is not Midam's link")
                offPath = false
            case .failure(.missingScript):
                result = String(localized: "The midam script is missing from this copy of Midam.")
                offPath = false
            case .failure(.failed(let why)):
                result = String(format: String(localized: "Couldn't install: %@"), why)
                offPath = false
            }
            AccessibilityNotification.Announcement(result ?? "").post()
        }
    }
}

struct ResetRow: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Reset to Defaults") { Pref.reset() }
                .actionButton()
        }
    }
}

extension View {
    /// An ordinary action: a native push button without the app tint, so the grey dark-mode
    /// accent never greys an enabled label. Disabled keeps the native disabled look.
    func actionButton() -> some View {
        buttonStyle(.bordered).tint(nil).foregroundStyle(.primary)
    }

    /// The one primary action in its context: filled ink with white in light, warm off-white with
    /// ink in dark (14.4:1 and 11.3:1). Disabled falls back to the native bordered look.
    func primaryButton() -> some View { modifier(PrimaryButton()) }
}

private struct PrimaryButton: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    private static func pair(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) {
            let v = $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }
    static let fill = pair(light: 0x2b2a27, dark: 0xe8e4dc)
    static let label = pair(light: 0xffffff, dark: 0x2b2a27)

    func body(content: Content) -> some View {
        if isEnabled {
            content.buttonStyle(Filled())
        } else {
            content.actionButton()
        }
    }

    /// Drawn by hand: a native prominent button keeps its white label on the light dark-mode fill.
    private struct Filled: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(PrimaryButton.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(PrimaryButton.fill.opacity(configuration.isPressed ? 0.8 : 1),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
    }
}

struct GeneralSettings: View {
    @AppStorage(Pref.size) private var size = Knob.size.initial
    @AppStorage(Pref.tracking) private var tracking = Spacing.normal
    @AppStorage(Pref.leading) private var leading = Spacing.normal
    @AppStorage(Pref.paragraph) private var paragraph = Spacing.normal
    @AppStorage(Pref.measure) private var measure = Spacing.normal

    var body: some View {
        Form {
            Section {
                slider(.size, $size)
                PresetPicker(spacing: .tracking, index: $tracking).pickerStyle(.segmented)
                PresetPicker(spacing: .leading, index: $leading).pickerStyle(.segmented)
            }
            Section {
                PresetPicker(spacing: .paragraph, index: $paragraph).pickerStyle(.segmented)
                PresetPicker(spacing: .measure, index: $measure).pickerStyle(.segmented)
            }
            LanguageSection()
            HiddenProjectsSection()
            CacheSection()
            CommandLineSection()
            ResetRow()
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ k: Knob, _ v: Binding<Double>) -> some View {
        LabeledContent(k.label) {
            HStack(spacing: 10) {
                Slider(value: v, in: k.range, step: k.step) { Text(k.label) }
                    .labelsHidden()
                    .accessibilityValue(Text(verbatim: k.format(v.wrappedValue)))
                Text(verbatim: k.format(v.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .muted))
                    .frame(width: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct FontSettings: View {
    /// The body font list's two tabs: 추천 (curated, with hints) and 모든 글꼴 (every family).
    enum ListTab: Hashable { case recommended, all }

    @AppStorage(Pref.font) private var font = ""
    @AppStorage(Pref.codeFont) private var codeFont = ""
    @State private var query = ""
    @State private var tab = ListTab.recommended
    private let fonts = Fonts.all
    private let mono = Fonts.monospaced
    @FocusState private var searching: Bool
    private let route = SettingsRoute.shared

    private func hit(_ family: String, _ name: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query) || family.localizedCaseInsensitiveContains(query)
    }

    private var recommended: [RecommendedFonts.Pick] {
        RecommendedFonts.body.filter { hit($0.family, Fonts.displayName($0.family)) }
    }

    private var matches: [(family: String, name: String)] {
        query.isEmpty ? fonts : fonts.filter { hit($0.family, $0.name) }
    }

    /// The families in the active tab, in display order (what ↓/↑ step through).
    private var shown: [String] { tab == .recommended ? recommended.map(\.family) : matches.map(\.family) }

    /// 추천 unless the current font is not in it, so the selection is visible.
    private var openingTab: ListTab {
        RecommendedFonts.body.contains { $0.family == font } ? .recommended : .all
    }

    var body: some View {
        let codePicks = RecommendedFonts.code
        let codePicked = Set(codePicks.map(\.family))
        Form {
            Section {
                TextField("Search Fonts", text: $query, prompt: Text("Search Fonts"))
                    .focused($searching)
                    .onKeyPress(.downArrow) { moveFont(1) }
                    .onKeyPress(.upArrow) { moveFont(-1) }
                Picker("Font List", selection: $tab) {
                    Text("Recommended").tag(ListTab.recommended)
                    Text("All Fonts").tag(ListTab.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                FontList(font: $font, recommended: tab == .recommended ? recommended : [], fonts: tab == .all ? matches : [])
                    .onKeyPress(.downArrow) { moveFont(1) }
                    .onKeyPress(.upArrow) { moveFont(-1) }
                    .overlay { if shown.isEmpty { noMatches } }
            } header: {
                Text("Body Font")
            } footer: {
                Text("Hangul is shown in the system font when the chosen font has none.")
                    .foregroundStyle(Color(nsColor: .muted))
            }
            Section {
                // A pop-up menu cannot hold tabs; it keeps the two as menu sections.
                Picker("Code Font", selection: $codeFont) {
                    Section("Recommended") {
                        ForEach(codePicks, id: \.family) { p in
                            VStack(alignment: .leading) {
                                p.family.isEmpty ? Text("System Monospaced") : Text(verbatim: p.family)
                                Text(verbatim: FontList.hintLine(p))
                            }
                            .tag(p.family)
                        }
                    }
                    Section("All Fonts") {
                        ForEach(mono.filter { !codePicked.contains($0) }, id: \.self) { Text(verbatim: $0).tag($0) }
                        if !codeFont.isEmpty, !mono.contains(codeFont), !codePicked.contains(codeFont) {
                            Text(verbatim: codeFont).tag(codeFont)
                        }
                    }
                }
            }
            ResetRow()
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { tab = openingTab; focusIfAsked() }
        .onChange(of: route.focusFontSearch) { focusIfAsked() }
    }

    /// No match in the active tab; a quiet link to the other tab when it has some.
    private var noMatches: some View {
        let other = tab == .recommended ? matches.count : recommended.count
        return VStack(spacing: 6) {
            Text("No fonts match").foregroundStyle(Color(nsColor: .muted))
            if other > 0 {
                Group {
                    if tab == .recommended {
                        Button("\(other) in All Fonts") { tab = .all }
                    } else {
                        Button("\(other) in Recommended") { tab = .recommended }
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    /// ↓/↑ in the search field step through the active tab's fonts.
    private func moveFont(_ d: Int) -> KeyPress.Result {
        let ids = shown
        guard !ids.isEmpty else { return .ignored }
        let i = ids.firstIndex(of: font).map { min(max($0 + d, 0), ids.count - 1) } ?? 0
        font = ids[i]
        return .handled
    }

    /// From 글꼴 선택… or 변경…: clear the search, show the tab holding the current font, focus the field.
    private func focusIfAsked() {
        guard route.focusFontSearch else { return }
        route.focusFontSearch = false
        query = ""
        tab = openingTab
        Task { searching = true } // after the field is in the window
    }
}

/// The body font list for one tab: 추천 rows carry a quiet hint line (bundled ones tagged 내장);
/// 모든 글꼴 rows are plain. Each name is set in its own face. Selection is quiet (hairline ground,
/// ink text) rather than the system highlight, which a chosen system accent would turn blue.
/// One focusable stop; ↓/↑ (set by the caller) move the selection, a click picks a row.
struct FontList: View {
    @Binding var font: String
    let recommended: [RecommendedFonts.Pick]
    let fonts: [(family: String, name: String)]

    /// "Built-in · hint" as one line, for the code font menu.
    static func hintLine(_ p: RecommendedFonts.Pick) -> String {
        let hint = String(localized: String.LocalizationValue(p.hint))
        return p.builtIn ? String(localized: "Built-in") + " · " + hint : hint
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recommended, id: \.family) { p in row(p.family, name: Fonts.displayName(p.family), pick: p) }
                    ForEach(fonts, id: \.family) { f in row(f.family, name: f.name) }
                }
                .padding(4)
            }
            .frame(height: 260)
            .focusable()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Body Font")
            .onAppear { proxy.scrollTo(font, anchor: .center) }
            .onChange(of: font) { proxy.scrollTo(font) }
            .onChange(of: recommended.isEmpty) { proxy.scrollTo(font, anchor: .center) } // the tab changed
        }
    }

    private func row(_ family: String, name: String, pick: RecommendedFonts.Pick? = nil) -> some View {
        let on = family == font
        return Button { font = family } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(family.isEmpty ? .system(size: 13) : Font(Fonts.ns(family, size: 13)))
                    .lineLimit(1)
                    .foregroundStyle(Color(nsColor: .ink))
                if let pick {
                    HStack(spacing: 6) {
                        if pick.builtIn {
                            Text("Built-in")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .overlay(Capsule().strokeBorder(Color(nsColor: .hairline)))
                        }
                        Text(LocalizedStringKey(pick.hint))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .muted))
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, pick == nil ? 3 : 4)
            .background(on ? Color(nsColor: .hairline) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false) // one tab stop for the list; ↓/↑ move within it
        .id(family)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
