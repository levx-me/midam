// Checks the "last read" snapshots (one per document, bounded) in a scratch directory. Run:
// swiftc Sources/Midam/Baseline.swift tools/BaselineTest/main.swift -o /tmp/bl && /tmp/bl
import Foundation

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("midam-bl-\(UUID().uuidString)")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let store = dir.appendingPathComponent("Baselines")
let doc = dir.appendingPathComponent("doc.md")
try "# Now".write(to: doc, atomically: true, encoding: .utf8)
let flush = { Baseline.queue.sync {} } // writes are queued

// Keys: the realpath's SHA-256, so a symlink and the file it points to share one; a missing path
// is hashed as given.
assert(DocKey.hash("/nonexistent/midam-doc.md") == "99c801b4cb96a3f54dd8d223774a43bdefeee36500a65c96b4be045b49ce9894")
let link = dir.appendingPathComponent("link.md")
try fm.createSymbolicLink(at: link, withDestinationURL: doc)
assert(DocKey.hash(link.path) == DocKey.hash(doc.path) && DocKey.hash(doc.path) != DocKey.hash(dir.appendingPathComponent("other.md").path))
assert(Baseline.file(for: doc, in: store).lastPathComponent == DocKey.hash(doc.path))

// Never read: nothing.
assert(Baseline.read(doc, in: store) == nil && Baseline.lastRead(doc, in: store) == nil)

// Round trip; a second write replaces the one snapshot; lastRead is the file's mtime, set by the write.
let before = Date().addingTimeInterval(-2)
Baseline.write(doc, text: "# First\n\n안녕", in: store)
assert(Baseline.read(doc, in: store) == "# First\n\n안녕")
Baseline.write(link, text: "# Second", in: store)
assert(Baseline.read(doc, in: store) == "# Second")
assert(try! fm.contentsOfDirectory(atPath: store.path).count == 1)
let read = Baseline.lastRead(doc, in: store)!
assert(read > before && read < Date().addingTimeInterval(2))
try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: Baseline.file(for: doc, in: store).path)
assert(Baseline.lastRead(doc, in: store) == Date(timeIntervalSince1970: 1_000_000))
_ = Baseline.read(doc, in: store)
assert(Baseline.lastRead(doc, in: store) == Date(timeIntervalSince1970: 1_000_000)) // reading it back is no new read

// The folder is 0700 and the files 0600.
let perms = { (u: URL) in (try! fm.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
assert(perms(store) == 0o700 && perms(Baseline.file(for: doc, in: store)) == 0o600)

// A corrupt file (not UTF-8) is nil and deleted, never a crash.
let f = Baseline.file(for: doc, in: store)
try Data([0x23, 0xff, 0xfe, 0x00, 0xc3]).write(to: f)
assert(Baseline.read(doc, in: store) == nil && !fm.fileExists(atPath: f.path))

// Too large a document keeps no snapshot, not even an older one.
Baseline.write(doc, text: "small", in: store)
Baseline.write(doc, text: String(repeating: "x", count: Baseline.fileLimit + 1), in: store)
assert(Baseline.read(doc, in: store) == nil && !fm.fileExists(atPath: f.path))

// Eviction drops the least recently read first, after a write too.
let docs = (0..<3).map { dir.appendingPathComponent("doc\($0).md") }
for (i, d) in docs.enumerated() {
    Baseline.write(d, text: String(repeating: "y", count: 1000), in: store)
    flush()
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i + 1) * 10)], ofItemAtPath: Baseline.file(for: d, in: store).path)
}
Baseline.evict(limit: 2000, in: store)
assert(Baseline.read(docs[0], in: store) == nil && Baseline.read(docs[1], in: store) != nil && Baseline.read(docs[2], in: store) != nil)
Baseline.write(docs[0], text: String(repeating: "z", count: 1000), in: store) // the newest: doc1 goes
flush()
Baseline.evict(limit: 2000, in: store)
assert(Baseline.read(docs[0], in: store) != nil && Baseline.read(docs[1], in: store) == nil && Baseline.read(docs[2], in: store) != nil)
print("baseline: checks passed")
