import CryptoKit
import Foundation

/// A file's mtime and size, from the same open file the text was read through.
struct FileStamp: Codable, Equatable {
    var mtime: Double
    var size: Int
}

/// What a cached render was made from. Any difference is a miss: the file (resolved path, mtime,
/// size), the reading settings and colour theme (diagram colours follow the theme), and the app
/// build (a new renderer may draw differently).
struct RenderKey: Codable, Equatable {
    var path: String
    var mtime: Double
    var size: Int
    var settings: String
    var version: String
}

/// The last finished 읽기 render of each document (the #content HTML after the diagram, math and
/// highlight passes), so a tab shows its page at once on relaunch while the real render runs.
/// One JSON file per document under Caches, at most 100 MB in all (least recently used go first).
/// Never the 원본 view, which is cheap to build. Foundation only: checked by tools/RenderCacheTest.
enum RenderCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.midam.Midam/render", isDirectory: true)
    static let limit = 100_000_000
    /// A page larger than this is not cached; a cache file larger than the page limit plus room for
    /// the key and JSON escaping is corrupt.
    static let pageLimit = 10_000_000
    static let queue = DispatchQueue(label: queueName, qos: .utility)
    private static let queueName = "dev.midam.render-cache" // not a UI string

    /// The app build: version, build number and the executable's mtime (every build changes it).
    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let built = Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return "\(info["CFBundleShortVersionString"] ?? "")-\(info["CFBundleVersion"] ?? "")-\(built?.timeIntervalSince1970 ?? 0)"
    }()

    /// A stable digest of JSON-able settings (keys sorted).
    static func digest(_ settings: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a file's text with its stamp taken from the same open file (fstat on the descriptor
    /// read), so a save in between can never pair old text with a new mtime. The stamp is nil if
    /// the file changed size while it was read: that text is shown but not cached.
    static func read(_ url: URL) -> (text: String, stamp: FileStamp?)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var st = stat()
        let statted = fstat(h.fileDescriptor, &st) == 0
        guard let data = try? h.readToEnd() ?? Data() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard statted, Int(st.st_size) == data.count else { return (text, nil) }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (text, FileStamp(mtime: mtime, size: data.count))
    }

    /// The key for text read from `url` with `stamp`.
    static func key(for url: URL, stamp: FileStamp, settings: String, version: String = version) -> RenderKey {
        RenderKey(path: url.resolvingSymlinksInPath().path, mtime: stamp.mtime, size: stamp.size, settings: settings, version: version)
    }

    static func file(for path: String, in dir: URL = directory) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".json")
    }

    private struct Entry: Codable {
        var key: RenderKey
        var html: String
    }

    /// The cached page for `key`, or nil. A corrupt or oversized file is deleted; a stale one is
    /// left for the next store to replace. A hit counts as a use, for eviction.
    static func load(_ key: RenderKey, in dir: URL = directory) -> String? {
        let url = file(for: key.path, in: dir)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        guard size <= pageLimit * 2, let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.html.utf8.count <= pageLimit
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard entry.key == key else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry.html
    }

    /// Writes the page for `key` (on the caller's thread: use `queue`), then keeps the total in
    /// bounds. The folder is 0700 and each file 0600: rendered pages are the reader's own.
    static func store(_ key: RenderKey, html: String, in dir: URL = directory) {
        guard html.utf8.count <= pageLimit, let data = try? JSONEncoder().encode(Entry(key: key, html: html)) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let url = file(for: key.path, in: dir)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        evict(in: dir)
    }

    /// Bumped by clear(); a delayed write made before it is dropped. Touched on `queue` only.
    nonisolated(unsafe) private static var generation = 0

    /// Stores on `queue` after `delay`; cancel the returned item to drop it. Made here, outside the
    /// main actor, so the closure is not main-actor isolated (it runs on the cache queue).
    static func storeLater(_ key: RenderKey, html: String, after delay: Double = 1, in dir: URL = directory) -> DispatchWorkItem {
        let made = queue.sync { generation }
        let item = DispatchWorkItem { if generation == made { store(key, html: html, in: dir) } }
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    /// Deletes the least recently used files until the total is within `limit`.
    static func evict(limit: Int = limit, in dir: URL = directory) {
        var files = entries(in: dir)
        var total = files.reduce(0) { $0 + $1.size }
        files.sort { $0.used < $1.used }
        for f in files where total > limit {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }

    static func size(in dir: URL = directory) -> Int { entries(in: dir).reduce(0) { $0 + $1.size } }

    /// Empties the cache, and drops any write still waiting (on `queue`, after what runs there now).
    static func clear(in dir: URL = directory) {
        queue.sync {
            generation += 1
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func entries(in dir: URL) -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
    }
}
