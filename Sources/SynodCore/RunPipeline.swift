import Foundation

/// Options of one run.
public struct RunOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable {
        case ordered, proportional
    }

    public var mode: Mode
    /// Empty by default: the program's own seed.
    public var seed: UInt64?

    public init(mode: Mode = .ordered, seed: UInt64? = nil) {
        self.mode = mode
        self.seed = seed
    }
}

/// What a run produced.
public enum RunOutcome: Sendable {
    /// `synod check` found errors; nothing was run.
    case diagnostics(CheckReport)
    /// `synod run` exited 1 without a trace and scene; the raw text goes to Problems.
    case rawProblems(String)
    /// The program ran (or failed while running and left a trace and a partial scene). Check
    /// `status.fault` and `status.lookFault` for the failure banner.
    case ran(status: RunStatus, sceneText: String, scene: SceneSummary, trace: TraceIndex)
}

/// A run together with the check that preceded it.
public struct RunResult: Sendable {
    public let outcome: RunOutcome
    /// The report of `synod check --json --tokens` (with the tokens of every file of the program),
    /// when it could be parsed; nil when the check printed no readable report.
    public let check: CheckReport?
}

public enum PipelineError: Error, Equatable, LocalizedError {
    /// The tool failed (exit 2 or an unexpected exit).
    case toolFailed(exitCode: Int32, stderr: String)
    /// The tool succeeded but its output is missing or unreadable.
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let c, let e):
            let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "synod failed (exit \(c))" : "synod failed (exit \(c)): \(t)"
        case .badOutput(let m): return m
        }
    }
}

/// Check, run and load: `synod check --json --tokens`, then `synod run` into the cache, then the parsed
/// results. Never writes into the workspace.
public struct RunPipeline: Sendable {
    public let workspace: Workspace
    public let runner: SynodRunner
    public let cache: CachePaths

    public init(workspace: Workspace, runner: SynodRunner, cache: CachePaths = .default) {
        self.workspace = workspace
        self.runner = runner
        self.cache = cache
    }

    /// Runs one program from the module root.
    public func run(program: Workspace.Program, options: RunOptions = RunOptions()) async throws -> RunOutcome {
        try await runDetailed(program: program, options: options).outcome
    }

    /// Like `run`, and also returns the check report (tokens included) for the editor.
    public func runDetailed(program: Workspace.Program, options: RunOptions = RunOptions()) async throws -> RunResult {
        let rel = program.relPath
        let root = workspace.root

        // 1. check
        let check = try await runner.exec(["check", "--json", "--tokens", rel], cwd: root)
        if check.exitCode >= 2 || (check.exitCode != 0 && check.exitCode != 1) {
            throw PipelineError.toolFailed(exitCode: check.exitCode, stderr: check.stderrText)
        }
        var report: CheckReport?
        if !check.stdout.isEmpty {
            do {
                let parsed = try CheckReport.parse(check.stdout)
                report = parsed
                if parsed.hasErrors { return RunResult(outcome: .diagnostics(parsed), check: parsed) }
            } catch let e as FormatError {
                if case .unsupported = e { throw e }
                if check.exitCode == 1 { return RunResult(outcome: .rawProblems(check.stdoutText), check: nil) }
                throw e
            }
        } else if check.exitCode == 1 {
            return RunResult(outcome: .rawProblems(check.stderrText), check: nil)
        }

        // 2. run
        let dir = try cache.makeRunFolder(moduleRoot: root, program: rel)
        let tracePath = dir.appendingPathComponent("trace.jsonl")
        let scenePath = dir.appendingPathComponent("scene.json")
        var args = ["run", rel, "--mode", options.mode.rawValue]
        if let seed = options.seed { args += ["--seed", String(seed)] }
        args += ["--trace", tracePath.path, "--scene", scenePath.path, "--style", "short", "--color", "never"]
        let result = try await runner.exec(args, cwd: root)
        if result.exitCode >= 2 || result.exitCode < 0 {
            throw PipelineError.toolFailed(exitCode: result.exitCode, stderr: result.stderrText)
        }
        let statusText = result.stdoutText
        let fm = FileManager.default
        let haveFiles = fm.fileExists(atPath: tracePath.path) && fm.fileExists(atPath: scenePath.path)
        if !haveFiles {
            if result.exitCode == 1 {
                let text = statusText.isEmpty ? result.stderrText : statusText
                return RunResult(outcome: .rawProblems(text), check: report)
            }
            throw PipelineError.badOutput("synod run wrote no trace or scene")
        }

        // 3-6. parse
        let status = RunStatusParser.parse(statusText)
        do {
            let sceneData = try Data(contentsOf: scenePath)
            let sceneText = String(decoding: sceneData, as: UTF8.self)
            let summary = try SceneSummary.parse(sceneData)
            let trace = try Trace.parse(try Data(contentsOf: tracePath))
            let outcome = RunOutcome.ran(status: status, sceneText: sceneText, scene: summary, trace: TraceIndex(trace: trace, scene: summary))
            return RunResult(outcome: outcome, check: report)
        } catch let e as FormatError {
            throw e
        } catch {
            throw PipelineError.badOutput("could not read the run output: \(error.localizedDescription)")
        }
    }
}
