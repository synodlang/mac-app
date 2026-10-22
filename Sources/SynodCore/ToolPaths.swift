import Foundation

/// Where the bundled `synod` binary and the examples live.
public struct ToolPaths: Sendable, Equatable {
    /// The `synod` executable.
    public var synod: URL
    /// The folder of bundled example programs (a module), if present.
    public var examples: URL?

    public init(synod: URL, examples: URL? = nil) {
        self.synod = synod
        self.examples = examples
    }

    /// Resolves the tools from a base folder: an app bundle's `Contents/Resources` (binary in
    /// `../Helpers/synod`, examples in `examples`) or the repo's `.deps` folder (`synod/synod`).
    public init(baseURL: URL, avoiding running: [URL] = ToolPaths.runningExecutables()) {
        let fm = FileManager.default
        let candidates = [
            baseURL.appendingPathComponent("../Helpers/synod"),
            baseURL.appendingPathComponent("Helpers/synod"),
            baseURL.appendingPathComponent("synod/synod"),
            baseURL.appendingPathComponent("synod"),
        ].map(\.standardizedFileURL)
        var found = candidates.first { c in !running.contains { Self.sameFile(c, $0) } }
        for c in candidates {
            // On a case-insensitive filesystem `.build/debug/synod` is the app's own `Synod`.
            if running.contains(where: { Self.sameFile(c, $0) }) { continue }
            var isDir: ObjCBool = false
            if fm.isExecutableFile(atPath: c.path), fm.fileExists(atPath: c.path, isDirectory: &isDir), !isDir.boolValue {
                found = c
                break
            }
        }
        let ex = baseURL.appendingPathComponent("examples").standardizedFileURL
        self.init(synod: found ?? candidates[0], examples: fm.fileExists(atPath: ex.path) ? ex : nil)
    }

    /// The executable this process runs: `Bundle.main.executableURL` and `arguments[0]`.
    public static func runningExecutables() -> [URL] {
        var list: [URL] = []
        if let b = Bundle.main.executableURL { list.append(b) }
        if let a0 = CommandLine.arguments.first, !a0.isEmpty {
            list.append(URL(fileURLWithPath: a0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        }
        return list
    }

    /// True when both paths are the same file (same device and inode, so case and symlinks do not matter).
    public static func sameFile(_ a: URL, _ b: URL) -> Bool {
        func identity(_ u: URL) -> (Int, Int)? {
            var st = stat()
            guard stat(u.path, &st) == 0 else { return nil }
            return (Int(st.st_dev), Int(st.st_ino))
        }
        guard let x = identity(a), let y = identity(b) else { return false }
        return x == y
    }

    /// The tools of a running app (`Bundle.main.resourceURL`).
    public static func bundled() -> ToolPaths? {
        Bundle.main.resourceURL.map { ToolPaths(baseURL: $0) }
    }

    /// The repo's `.deps` folder (filled by `scripts/fetch-deps.sh`), found from this source file;
    /// nil when it has no `synod` binary.
    public static func repoDeps(file: String = #filePath) -> ToolPaths? {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let paths = ToolPaths(baseURL: url.appendingPathComponent(".deps"))
        return paths.isUsable ? paths : nil
    }

    /// True when the `synod` file exists and is executable.
    /// The running executable never counts: it is not the compiler.
    public var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: synod.path)
            && !Self.runningExecutables().contains { Self.sameFile(synod, $0) }
    }

    /// The same tools with the `synod` path replaced by a user setting; empty or nil keeps it.
    public func overriding(synodPath: String?) -> ToolPaths {
        guard let p = synodPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return self }
        var copy = self
        copy.synod = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        return copy
    }
}
