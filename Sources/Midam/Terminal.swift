import AppKit
import os
import SwiftTerm

/// One agent tab's terminal: a SwiftTerm view running the agent CLI in a PTY.
@MainActor final class AgentTerminal: ObservableObject {
    enum State: Equatable { case notStarted, running, ended(exitCode: Int32?) } // nil: killed by a signal or failed to start
    enum Activity: Equatable { case idle, streaming, waiting }

    @Published private(set) var state: State = .notStarted
    /// For the tab's dot: streaming while output arrives, waiting once it has gone quiet after output.
    @Published private(set) var activity: Activity = .idle
    private(set) var tab: TerminalTabState
    let view: AgentTerminalView

    var isRunning: Bool { state == .running }
    var title: String { tab.title }
    /// When the agent last printed (per output batch), for status derived later; not published:
    /// it changes many times a second.
    var lastOutput: Date? { output.withLock { $0 } }

    private let output = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private var ticker: Task<Void, Never>?
    private let events = Events()

    init(_ tab: TerminalTabState) {
        self.tab = tab
        view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.font = Self.font()
        view.project = tab.project
        events.owner = self
        view.processDelegate = events
        view.setProcessOutputHandler { [output] in output.withLock { $0 = Date() } }
    }

    /// Where ⌘-clicked Markdown paths go: the file and its line, if the path had one.
    var openLink: ((URL, Int?) -> Void)? {
        get { view.openLink }
        set { view.openLink = newValue }
    }

    /// Runs the tab's agent (again, after it ended). Does nothing while it runs or when the stored
    /// session id is invalid.
    func start() {
        guard !isRunning, let launch = tab.launch else { return }
        let argv = launch.argv()
        output.withLock { $0 = nil }
        activity = .idle
        state = .running
        view.startProcess(executable: argv[0], args: Array(argv.dropFirst()), environment: AgentLaunch.environment(),
                          currentDirectory: launch.project.path)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return } // a closed tab's ticker stops
                self.tick()
            }
        }
    }

    /// Hang up, as closing a terminal window does; kill after `grace` seconds if the agent stays.
    func terminate(grace: TimeInterval = 2) {
        guard isRunning else { return }
        let pid = view.process.shellPid
        guard pid > 0 else { view.terminate(); return }
        killpg(pid, SIGHUP) // forkpty made the agent a session and group leader: its tools hang up too
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self, self.isRunning, self.view.process.shellPid == pid else { return }
            killpg(pid, SIGKILL)
        }
    }

    /// Types `text` into the agent as one paste (bracketed). False when it is not running, or the
    /// text has several lines and the agent did not turn bracketed paste on (see BracketedPaste).
    @discardableResult func paste(_ text: String) -> Bool {
        guard isRunning, let bytes = BracketedPaste.bytes(text, bracketed: view.terminalStateSnapshot().bracketedPasteMode) else { return false }
        view.send(bytes)
        return true
    }

    /// ⌘K (a menu command: SwiftTerm's key handling is closed to subclasses): clears the scrollback,
    /// as in Terminal; the screen is the agent's to redraw.
    func clear() { view.clearScrollback() }

    // ponytail: streaming/waiting is a timing guess (output in the last 0.5 s / none for 2 s after
    // output), not the agent's own state; read it from the agent's hooks or transcript if that matters.
    private func tick() {
        guard let last = lastOutput else { return }
        let quiet = Date().timeIntervalSince(last)
        let next: Activity = quiet < 0.5 ? .streaming : quiet >= 2 ? .waiting : activity
        if next != activity { activity = next }
    }

    fileprivate func ended(_ code: Int32?) {
        ticker?.cancel()
        ticker = nil
        activity = .idle
        state = .ended(exitCode: code)
    }

    /// The Code Font setting at the terminal's size, else the system monospaced font.
    static func font(size: CGFloat = 13) -> NSFont {
        let family = UserDefaults.standard.string(forKey: Pref.codeFont) ?? ""
        return (family.isEmpty ? nil : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// SwiftTerm's process callbacks (the view keeps it weakly; the terminal keeps it alive).
    private final class Events: LocalProcessTerminalViewDelegate {
        weak var owner: AgentTerminal?
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { owner?.ended(exitCode) }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) { owner?.ended(nil) }
    }
}

/// SwiftTerm's view with Midam's ⌘-click on Markdown paths, resolved against the tab's project
/// (SwiftTerm's own link detection resolves relative paths against Midam's cwd).
final class AgentTerminalView: LocalProcessTerminalView {
    var project: URL?
    var openLink: ((URL, Int?) -> Void)?
    private var pressed: (url: URL, line: Int?)?

    override func mouseDown(with event: NSEvent) {
        pressed = event.modifierFlags.contains(.command) ? link(at: event) : nil
        if pressed == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = pressed else { return super.mouseUp(with: event) }
        pressed = nil
        if link(at: event)?.url == p.url { openLink?(p.url, p.line) }
    }

    private func link(at event: NSEvent) -> (url: URL, line: Int?)? {
        guard let project, openLink != nil else { return nil }
        // The cell under the pointer, from the font's cell size as SwiftTerm measures it ("W", line height).
        let p = convert(event.locationInWindow, from: nil)
        var chars: [UniChar] = [0x57], glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1) else { return nil }
        let cellWidth = font.advancement(forGlyph: NSGlyph(glyphs[0])).width
        let cellHeight = ceil(font.ascender - font.descender + font.leading)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let row = Int((bounds.maxY - p.y) / cellHeight), column = Int((p.x - bounds.minX) / cellWidth)
        let rows = terminalStateSnapshot().visibleRows
        guard let snapshot = rows.first(where: { $0.row == row }) else { return nil }
        let text = snapshot.text
        let n = TerminalLinks.character(atColumn: column, cellWidths: snapshot.cellWidths)
        guard n < text.count else { return nil }
        let at = text.index(text.startIndex, offsetBy: n)
        return TerminalLinks.find(in: text, project: project).first { $0.range.contains(at) }.map { ($0.url, $0.line) }
    }
}
