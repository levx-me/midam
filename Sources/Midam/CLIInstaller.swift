import Foundation

enum CLIInstallError: Error, Equatable {
    case missingScript
    /// `~/.local/bin/midam` exists and is not our symlink: left alone.
    case occupied(String)
    case failed(String)
}

/// Settings > "Install `midam` command": a symlink `~/.local/bin/midam` to the bundled script (no
/// admin rights). Foundation only: checked by tools/ReplyTest.
enum CLIInstaller {
    static let binDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)

    /// Links `bin/midam` to `script`. An existing symlink into a Midam bundle (an older install or
    /// another copy of the app) is replaced; a regular file or any other symlink is refused.
    @discardableResult
    static func install(script: URL? = Bundle.main.resourceURL?.appendingPathComponent("midam"),
                        bin: URL = binDir, path: String? = nil) throws -> (link: URL, onPath: Bool) {
        let fm = FileManager.default
        guard let script, fm.isExecutableFile(atPath: script.path) else { throw CLIInstallError.missingScript }
        let link = bin.appendingPathComponent("midam")
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                guard dest == script.path || dest.hasSuffix("/Contents/Resources/midam") else { throw CLIInstallError.occupied(dest) }
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                throw CLIInstallError.occupied(link.path)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: script)
        } catch let e as CLIInstallError {
            throw e
        } catch {
            throw CLIInstallError.failed(error.localizedDescription)
        }
        return (link, onPath(bin.path, in: path ?? loginPATH() ?? ""))
    }

    static func onPath(_ dir: String, in path: String) -> Bool {
        path.split(separator: ":").contains { $0 == dir || $0 == dir + "/" }
    }

    /// PATH as the user's login shell sees it (a GUI app's own PATH is minimal). Interactive too,
    /// since many people export PATH from .zshrc; rc noise is skipped by a marker. Nil on failure
    /// or after 3 s.
    static func loginPATH() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lic", "printf '\\n@@PATH@@%s\\n' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").last { $0.hasPrefix("@@PATH@@") }.map { String($0.dropFirst(8)) }
    }
}
