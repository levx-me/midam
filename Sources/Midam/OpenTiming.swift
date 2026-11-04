import AppKit
import os

/// How long opening a document takes, step by step, to trace a slow open. Each line is one tab's
/// step, in ms since its web view was asked for; each open is also an "open" signpost interval
/// for Instruments. Read with:
/// log show --predicate 'subsystem == "dev.midam.Midam" AND category == "open"' --last 5m
enum OpenTiming {
    static let log = Logger(subsystem: "dev.midam.Midam", category: "open") // not a UI string
    static let signposter = OSSignposter(logger: log)

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// How long ago the event being handled now (the click or key that opened the file) happened, in ms.
    @MainActor static func sinceEvent() -> Double {
        guard let e = NSApp.currentEvent else { return -1 }
        return (ProcessInfo.processInfo.systemUptime - e.timestamp) * 1000
    }
}
