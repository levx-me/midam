// Checks the render cache's key and validity rules in a scratch directory. Run:
// swiftc Sources/Midam/RenderCache.swift tools/RenderCacheTest/main.swift -o /tmp/rc && /tmp/rc
import Foundation

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("midam-rc-\(UUID().uuidString)")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let cache = dir.appendingPathComponent("cache")
let doc = dir.appendingPathComponent("doc.md")
try "# Hi".write(to: doc, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: doc.path)

// Settings digests are stable and order-free, and change with any value.
let s1 = RenderCache.digest(["size": 1.0, "colors": ["bg": "#ffffff"], "font": ""])
assert(s1 == RenderCache.digest(["font": "", "colors": ["bg": "#ffffff"], "size": 1.0]))
let s2 = RenderCache.digest(["size": 1.1, "colors": ["bg": "#ffffff"], "font": ""])
let dark = RenderCache.digest(["size": 1.0, "colors": ["bg": "#1d1c1a"], "font": ""])
assert(s1 != s2 && s1 != dark)

// The key comes from the stamp of the read itself (the same open file), never a later stat.
func keyNow(_ settings: String, _ version: String) -> RenderKey {
    let r = RenderCache.read(doc)!
    return RenderCache.key(for: doc, stamp: r.stamp!, settings: settings, version: version)
}
let read1 = RenderCache.read(doc)!
assert(read1.text == "# Hi" && read1.stamp == FileStamp(mtime: 1_000_000, size: 4))
let k = keyNow(s1, "1-1-100")
assert(k.path == doc.resolvingSymlinksInPath().path && k.size == 4 && k.mtime == 1_000_000)
assert(RenderCache.read(dir.appendingPathComponent("gone.md")) == nil)
assert(RenderCache.load(k, in: cache) == nil)                       // nothing yet
RenderCache.store(k, html: "<h1 id=\"hi\">Hi</h1>", in: cache)
assert(RenderCache.load(k, in: cache) == "<h1 id=\"hi\">Hi</h1>")  // a hit

// Each part of the key: a different settings digest, build, mtime or size is a miss.
assert(RenderCache.load(keyNow(s2, "1-1-100"), in: cache) == nil)
assert(RenderCache.load(keyNow(dark, "1-1-100"), in: cache) == nil)
assert(RenderCache.load(keyNow(s1, "1-1-101"), in: cache) == nil)
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_001)], ofItemAtPath: doc.path)
assert(RenderCache.load(keyNow(s1, "1-1-100"), in: cache) == nil)
try "# Hi!".write(to: doc, atomically: true, encoding: .utf8)
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: doc.path)
assert(RenderCache.load(keyNow(s1, "1-1-100"), in: cache) == nil) // same mtime, new size
assert(RenderCache.key(for: doc, stamp: read1.stamp!, settings: s1, version: "1-1-100") == k) // the old read keeps its own stamp
assert(fm.fileExists(atPath: RenderCache.file(for: k.path, in: cache).path)) // a stale entry stays until replaced

// The folder is 0700 and the files 0600.
let perms = { (u: URL) in (try! fm.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
assert(perms(cache) == 0o700 && perms(RenderCache.file(for: k.path, in: cache)) == 0o600)

// Clear Cache drops a delayed write made before it.
_ = RenderCache.storeLater(k, html: "late", after: 0.2, in: cache)
RenderCache.clear(in: cache)
Thread.sleep(forTimeInterval: 0.5)
assert(!fm.fileExists(atPath: RenderCache.file(for: k.path, in: cache).path))
_ = RenderCache.storeLater(k, html: "kept", after: 0.1, in: cache) // one made after it still writes
Thread.sleep(forTimeInterval: 0.4)
assert(RenderCache.load(k, in: cache) == "kept")

// A corrupt file is a miss and is deleted.
let f = RenderCache.file(for: k.path, in: cache)
try Data("{not json".utf8).write(to: f)
assert(RenderCache.load(k, in: cache) == nil && !fm.fileExists(atPath: f.path))

// Too large a page is never written.
RenderCache.store(k, html: String(repeating: "x", count: RenderCache.pageLimit + 1), in: cache)
assert(!fm.fileExists(atPath: f.path))

// Eviction drops the least recently used first; size and clear.
var keys: [RenderKey] = []
for i in 0..<3 {
    var key = k
    key.path = "/doc\(i).md"
    RenderCache.store(key, html: String(repeating: "y", count: 1000), in: cache)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 10)], ofItemAtPath: RenderCache.file(for: key.path, in: cache).path)
    keys.append(key)
}
let each = RenderCache.size(in: cache) / 3
RenderCache.evict(limit: each * 2, in: cache)
assert(RenderCache.load(keys[0], in: cache) == nil && RenderCache.load(keys[2], in: cache) != nil)
RenderCache.clear(in: cache)
assert(RenderCache.size(in: cache) == 0)
print("render cache: checks passed")
