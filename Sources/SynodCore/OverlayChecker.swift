import Foundation

/// Checks the editor's unsaved buffers without writing into the workspace: the buffers go to the
/// app's cache folder, an `overlay.json` names them, and `synod check --json --tokens --overlay`
/// reads it (decisions 80 and 81). Unsaved text is never run.
public struct OverlayChecker: Sendable {
    public let workspace: Workspace
    public let runner: SynodRunner
    public let cache: CachePaths

    public init(workspace: Workspace, runner: SynodRunner, cache: CachePaths = .default) {
        self.workspace = workspace
        self.runner = runner
        self.cache = cache
    }

    /// `overlay/<sha256(moduleRoot)[0..16]>` under the cache root: the parent of every check's folder.
    public var overlayFolder: URL {
        cache.cacheRoot.appendingPathComponent("overlay")
            .appendingPathComponent(CachePaths.shortHash(workspace.root.standardizedFileURL.path))
    }

    /// Writes `overlay.json` and one file per buffer into a new folder under `overlayFolder` and
    /// returns the path of `overlay.json`. Keys are module-relative paths of existing files;
    /// values are the buffers' files, named `1.synod`, `2.synod`, ... in path order. The caller
    /// removes `overlayJSON.deletingLastPathComponent()` when the check is over (`check` does).
    public func writeOverlay(buffers: [String: String]) throws -> URL {
        let dir = overlayFolder.appendingPathComponent("c-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var replace: [String: String] = [:]
        for (n, path) in buffers.keys.sorted().enumerated() {
            let file = dir.appendingPathComponent("\(n + 1).synod")
            try Data(buffers[path]!.utf8).write(to: file, options: .atomic)
            replace[path] = file.path
        }
        let doc: [String: Any] = ["format": "synod-overlay/1", "replace": replace]
        let json = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes])
        let overlay = dir.appendingPathComponent("overlay.json")
        try json.write(to: overlay, options: .atomic)
        return overlay
    }

    /// Runs `synod check --json --tokens [--overlay …] <target>` from the module root and parses
    /// the report. `target` is a module-relative program or folder. With no `buffers` it is a
    /// plain check of the saved files. Throws `CancellationError` when cancelled (the process is
    /// terminated), `PipelineError.toolFailed` for exit 2 (for example an overlay key that is not
    /// an existing file) and `PipelineError.badOutput` when exit 1 comes without a report.
    public func check(target: String, buffers: [String: String] = [:]) async throws -> CheckReport {
        var args = ["check", "--json", "--tokens"]
        var cleanup: URL?
        if !buffers.isEmpty {
            let overlay = try writeOverlay(buffers: buffers)
            cleanup = overlay.deletingLastPathComponent()
            args += ["--overlay", overlay.path]
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        args.append(target)
        let result = try await runner.exec(args, cwd: workspace.root)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw PipelineError.toolFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
        guard !result.stdout.isEmpty else {
            throw PipelineError.badOutput(result.stderrText.isEmpty ? "synod check printed no report" : result.stderrText)
        }
        return try CheckReport.parse(result.stdout)
    }
}
