import CryptoKit
import Foundation

/// A document's name in Midam's per-document stores and for the `midam` CLI: the lowercase hex
/// SHA-256 of its realpath(3), or of the path as given when it does not exist. realpath, not URL
/// standardizing, which keeps /tmp and /private/tmp apart.
enum DocKey {
    static func path(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(Self.path(path).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// "The version I last read" (V3): one snapshot of each document's source, written when the reader
/// leaves it; the next visit's change marks are made against it. Not an archive: a write replaces
/// the snapshot. One file per document, named by DocKey, whose mtime is when it was last read
/// (`midam status` reads it too). At most 50 MB in all, the least recently read go first.
/// Foundation only: checked by tools/BaselineTest.
enum Baseline {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Midam/Baselines", isDirectory: true)
    static let limit = 50_000_000
    /// A larger document keeps no snapshot (so it shows no marks); a larger file is corrupt.
    static let fileLimit = 10_000_000
    /// Writes run here in order and reads wait for them: never call read or lastRead on it.
    static let queue = DispatchQueue(label: queueName, qos: .utility)
    private static let queueName = "dev.midam.baseline" // not a UI string

    static func file(for url: URL, in dir: URL = directory) -> URL {
        dir.appendingPathComponent(DocKey.hash(url.path))
    }

    /// The snapshot of `url`, or nil if there is none. A corrupt or oversized file is deleted.
    static func read(_ url: URL, in dir: URL = directory) -> String? {
        queue.sync {
            let f = file(for: url, in: dir)
            guard let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
            guard size <= fileLimit, let data = try? Data(contentsOf: f), let text = String(data: data, encoding: .utf8) else {
                try? FileManager.default.removeItem(at: f)
                return nil
            }
            return text
        }
    }

    /// When the snapshot of `url` was taken, or nil if there is none.
    static func lastRead(_ url: URL, in dir: URL = directory) -> Date? {
        queue.sync { (try? file(for: url, in: dir).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
    }

    /// Makes `text` the snapshot of `url` (on `queue`), then keeps the total in bounds. The folder
    /// is 0700 and each file 0600: what the reader read is their own.
    static func write(_ url: URL, text: String, in dir: URL = directory) {
        queue.async {
            let fm = FileManager.default, f = file(for: url, in: dir), data = Data(text.utf8)
            guard data.count <= fileLimit else {
                try? fm.removeItem(at: f) // an older, smaller snapshot would mark the wrong changes
                return
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            guard (try? data.write(to: f, options: .atomic)) != nil else { return }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
            evict(in: dir)
        }
    }

    /// Deletes the least recently read snapshots until the total is within `limit`.
    static func evict(limit: Int = limit, in dir: URL = directory) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        var files = urls.filter { $0.lastPathComponent.count == 64 }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (url: u, size: v?.fileSize ?? 0, read: v?.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        files.sort { $0.read < $1.read }
        for f in files where total > limit {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }
}
