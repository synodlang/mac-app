import Foundation

/// Runs `synod doc --json --scope <file> [--overlay …]` from the module root (decision 92:
/// completion items come only from here). Unsaved buffers go in through an overlay, like a check.
public struct DocRunner: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Exit 0: the scope of the file.
        case scope(DocReport)
        /// Exit 1: the package has diagnostics. The caller keeps its previous scope.
        case diagnostics(DocReport)
    }

    public let workspace: Workspace
    public let runner: SynodRunner
    public let cache: CachePaths

    public init(workspace: Workspace, runner: SynodRunner, cache: CachePaths = .default) {
        self.workspace = workspace
        self.runner = runner
        self.cache = cache
    }

    /// The arguments of the call (without the overlay path when `overlay` is nil).
    public static func arguments(file: String, overlay: URL?) -> [String] {
        var args = ["doc", "--json", "--scope", file]
        if let overlay { args += ["--overlay", overlay.path] }
        return args
    }

    /// Runs the command for `file` (module-relative, with `/` separators). Throws
    /// `CancellationError` when cancelled, `PipelineError.toolFailed` for exit 2 and
    /// `PipelineError.badOutput` when there is no document.
    public func scope(file: String, buffers: [String: String] = [:]) async throws -> Outcome {
        var overlay: URL?
        var cleanup: URL?
        if !buffers.isEmpty {
            let checker = OverlayChecker(workspace: workspace, runner: runner, cache: cache)
            let o = try checker.writeOverlay(buffers: buffers)
            overlay = o
            cleanup = o.deletingLastPathComponent()
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        let result = try await runner.exec(Self.arguments(file: file, overlay: overlay), cwd: workspace.root)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw PipelineError.toolFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
        guard !result.stdout.isEmpty else {
            throw PipelineError.badOutput(result.stderrText.isEmpty ? "synod doc printed no document" : result.stderrText)
        }
        let report = try DocReport.parse(result.stdout)
        return result.exitCode == 0 ? .scope(report) : .diagnostics(report)
    }
}

/// Keeps the last good scope per file: a result with diagnostics (exit 1) does not replace it,
/// so completion keeps working while a line is half typed.
public struct ScopeCache: Sendable, Equatable {
    public private(set) var scopes: [String: DocReport] = [:]
    public init() {}

    /// Applies an outcome for `file`; returns the scope to use now.
    @discardableResult
    public mutating func apply(_ outcome: DocRunner.Outcome, file: String) -> DocReport? {
        if case .scope(let r) = outcome { scopes[file] = r }
        return scopes[file]
    }

    public func scope(for file: String) -> DocReport? { scopes[file] }
    public mutating func remove(_ file: String) { scopes[file] = nil }
    public mutating func removeAll() { scopes = [:] }
}
