import Foundation

enum ReviewError: Error, Equatable {
    case scheme, action, query, path, notMarkdown, notFound, line
    /// The reply target is not a `reply.md` in the CLI's own temp dir (or is a symlink, or not ours).
    case reply
    /// The CLI's temp dir is gone (it timed out or was interrupted): fall back to the clipboard.
    case replyGone
    case write(String)
}

/// What a `midam://` URL asks for. The URL comes from any process on the machine (a web page can
/// open it too), so everything is checked here: documents only, an existing absolute path, and a
/// reply file only inside the CLI's own temp dir. Foundation only: checked by tools/ReplyTest.
///
///     midam://open?path=<abs>&line=<n>
///     midam://review?path=<abs>[&reply=<TMPDIR>/midam-review.XXXXXX/reply.md]
enum ReviewRequest: Equatable {
    case open(path: String, line: Int?)
    /// `reply` is the validated `<dir>/reply.md` of a waiting CLI; nil when nobody waits.
    case review(path: String, reply: URL?)

    static let extensions = ["md", "markdown", "mdown", "mkd"]
    static let dirPrefix = "midam-review."

    static func parse(_ url: URL, tempRoots: [String] = tempRoots()) -> Result<ReviewRequest, ReviewError> {
        guard url.scheme?.lowercased() == "midam" else { return .failure(.scheme) }
        let host = url.host?.lowercased()
        guard host == "open" || host == "review" else { return .failure(.action) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var q: [String: String] = [:]
        for item in items where ["path", "line", "reply"].contains(item.name) {
            guard q[item.name] == nil, let v = item.value else { return .failure(.query) }
            q[item.name] = v
        }
        guard let raw = q["path"], raw.hasPrefix("/"), !raw.contains("\0") else { return .failure(.path) }
        guard extensions.contains((raw as NSString).pathExtension.lowercased()) else { return .failure(.notMarkdown) }
        var st = stat()
        guard stat(raw, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notFound) }
        let path = DocKey.path(raw)

        if host == "open" {
            var line: Int?
            if let l = q["line"] {
                guard !l.isEmpty, l.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(l), n > 0 else { return .failure(.line) }
                line = n
            }
            return .success(.open(path: path, line: line))
        }
        guard let reply = q["reply"] else { return .success(.review(path: path, reply: nil)) }
        switch replyDir(reply, tempRoots: tempRoots) {
        case .success(let dir): return .success(.review(path: path, reply: URL(fileURLWithPath: dir + "/reply.md")))
        case .failure(let e): return .failure(e)
        }
    }

    /// The temp dirs a review dir may sit directly in: this process's, and `$TMPDIR` if it differs
    /// (both resolved, as /var is a symlink to /private/var).
    static func tempRoots() -> [String] {
        var roots: [String] = []
        for r in [NSTemporaryDirectory(), ProcessInfo.processInfo.environment["TMPDIR"] ?? ""] where !r.isEmpty {
            let real = DocKey.path(r)
            if !roots.contains(real) { roots.append(real) }
        }
        return roots
    }

    /// The resolved review dir for a `<dir>/reply.md` path: `dir` is a direct child of a temp root
    /// named `midam-review.<alnum>`, a real directory (not a symlink) owned by this user and not
    /// writable by group or others, and `reply.md` in it is not a symlink. No `.` or `..` parts.
    static func replyDir(_ reply: String, tempRoots: [String]) -> Result<String, ReviewError> {
        guard reply.hasPrefix("/"), !reply.contains("\0") else { return .failure(.reply) }
        let parts = reply.split(separator: "/")
        guard parts.count >= 2, parts.last == "reply.md", !parts.contains("."), !parts.contains("..") else { return .failure(.reply) }
        let name = String(parts[parts.count - 2])
        let suffix = name.dropFirst(dirPrefix.count)
        guard name.hasPrefix(dirPrefix), !suffix.isEmpty,
              suffix.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
        else { return .failure(.reply) }
        let dir = "/" + parts.dropLast().joined(separator: "/")

        var st = stat()
        guard lstat(dir, &st) == 0 else { return .failure(errno == ENOENT ? .replyGone : .reply) }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { return .failure(.reply) }
        let real = DocKey.path(dir)
        let parent = (real as NSString).deletingLastPathComponent
        guard (real as NSString).lastPathComponent == name, tempRoots.contains(where: { DocKey.path($0) == parent }) else { return .failure(.reply) }
        if lstat(real + "/reply.md", &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK { return .failure(.reply) }
        return .success(real)
    }

    /// Hands a finished reply to a waiting CLI: re-validates, then writes `reply.md` and after it
    /// `verdict` (the CLI waits for the latter), each through a temp file and rename inside the
    /// directory's descriptor, never following a symlink. Throws `.replyGone` when the CLI's dir is
    /// gone, so the caller can copy to the clipboard instead.
    static func deliver(reply markdown: String, verdict: Verdict, to replyFile: URL, tempRoots: [String] = tempRoots()) throws {
        let dir: String
        switch replyDir(replyFile.path, tempRoots: tempRoots) {
        case .success(let d): dir = d
        case .failure(let e): throw e
        }
        let fd = Darwin.open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw errno == ENOENT ? ReviewError.replyGone : .reply }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { throw ReviewError.reply }
        try write(Data(markdown.utf8), as: "reply.md", in: fd)
        try write(Data(verdict.rawValue.utf8), as: "verdict", in: fd)
    }

    private static func write(_ data: Data, as name: String, in dirfd: Int32) throws {
        var st = stat()
        if fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFLNK { throw ReviewError.reply }
        let tmp = ".\(name).\(UUID().uuidString)"
        let fd = openat(dirfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReviewError.write(String(cString: strerror(errno))) }
        do {
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try h.write(contentsOf: data)
            try h.close()
        } catch {
            unlinkat(dirfd, tmp, 0)
            throw ReviewError.write(error.localizedDescription)
        }
        guard renameat(dirfd, tmp, dirfd, name) == 0 else {
            let why = String(cString: strerror(errno))
            unlinkat(dirfd, tmp, 0)
            throw ReviewError.write(why)
        }
    }
}
