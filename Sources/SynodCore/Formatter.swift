import Foundation

/// Runs `synod fmt` on a saved file (decision 81): the one formatter.
public struct Formatter: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Exit 0. `changed` says whether the file differs from before, so the editor reloads it
        /// only then.
        case formatted(changed: Bool)
        /// Exit 1: the file could not be formatted (it has errors); it is left as it was. The text
        /// is what `fmt` printed; the editor shows diagnostics from the check instead.
        case refused(output: String)
    }

    public let workspace: Workspace
    public let runner: SynodRunner

    public init(workspace: Workspace, runner: SynodRunner) {
        self.workspace = workspace
        self.runner = runner
    }

    /// The arguments of one call: `fmt <rel> --style short --color never`.
    public static func arguments(relativePath: String) -> [String] {
        ["fmt", relativePath, "--style", "short", "--color", "never"]
    }

    /// Formats a module-relative file in place from the module root. Throws
    /// `PipelineError.toolFailed` for exit 2 or any other unexpected exit.
    public func format(relativePath: String) async throws -> Outcome {
        let url = workspace.url(forRelative: relativePath)
        let before = try? Data(contentsOf: url)
        let r = try await runner.exec(Self.arguments(relativePath: relativePath), cwd: workspace.root)
        switch r.exitCode {
        case 0:
            let after = try? Data(contentsOf: url)
            return .formatted(changed: before != after)
        case 1:
            let out = r.stdoutText + r.stderrText
            return .refused(output: out)
        default:
            throw PipelineError.toolFailed(exitCode: r.exitCode, stderr: r.stderrText)
        }
    }
}
