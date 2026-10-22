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
    public init(baseURL: URL) {
        let fm = FileManager.default
        let candidates = [
            baseURL.appendingPathComponent("../Helpers/synod"),
            baseURL.appendingPathComponent("Helpers/synod"),
            baseURL.appendingPathComponent("synod/synod"),
            baseURL.appendingPathComponent("synod"),
        ].map(\.standardizedFileURL)
        var found = candidates.first
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.isExecutableFile(atPath: c.path), fm.fileExists(atPath: c.path, isDirectory: &isDir), !isDir.boolValue {
                found = c
                break
            }
        }
        let ex = baseURL.appendingPathComponent("examples").standardizedFileURL
        self.init(synod: found ?? candidates[0], examples: fm.fileExists(atPath: ex.path) ? ex : nil)
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
    public var isUsable: Bool { FileManager.default.isExecutableFile(atPath: synod.path) }

    /// The same tools with the `synod` path replaced by a user setting; empty or nil keeps it.
    public func overriding(synodPath: String?) -> ToolPaths {
        guard let p = synodPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return self }
        var copy = self
        copy.synod = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        return copy
    }
}
