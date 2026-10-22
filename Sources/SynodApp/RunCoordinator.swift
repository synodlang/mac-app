import Foundation
import Observation
import SynodCore

/// Something that can run a program. `RunPipeline` is the real one; tests inject a fake.
protocol ProgramRunning: Sendable {
    func run(program: Workspace.Program, options: RunOptions) async throws -> RunOutcome
}

extension RunPipeline: ProgramRunning {}

/// A successful (or failed-but-traced) run, ready for the stage and the inspector.
struct LoadedRun: Sendable {
    /// Tells this load from any other, even of the same program (caches key on it).
    let id = UUID()
    /// `<module root>|<program path>`: equal keys mean "the same program as before".
    let programKey: String
    let sceneText: String
    let scene: SceneSummary
    let trace: TraceIndex
    let status: RunStatus
    let options: RunOptions
}

/// Runs programs on request: cancels what is in flight, drops stale results, debounces file
/// changes and maps the current fact onto the new run.
@MainActor @Observable
final class RunCoordinator {
    enum Trigger: Sendable { case fileChange, manual, mode, seed, selection }

    struct Request {
        var program: Workspace.Program
        var programKey: String
        var options: RunOptions
        var runner: any ProgramRunning
        /// Keep the stage at the same presentation time instead of mapping the current fact onto the
        /// new trace (Break it: the new events shift the fact numbers).
        var preserveTime = false
    }

    /// Quiet time before a file change starts a run.
    var debounce: Duration = .milliseconds(300)

    private(set) var generation = 0
    private(set) var isRunning = false
    private(set) var loaded: LoadedRun?
    /// True when the latest run failed and the stage still shows an older good run.
    private(set) var stale = false
    private(set) var diagnostics: CheckReport?
    private(set) var rawProblems: String?
    private(set) var errorMessage: String?

    /// The fact seq the viewer is at, asked when a result arrives.
    @ObservationIgnored var currentSeq: () -> Int? = { nil }
    /// Puts a run on the stage. `seek` is the time to move to, `keepTime` whether the stage keeps its time.
    @ObservationIgnored var apply: (LoadedRun, _ seek: Double?, _ keepTime: Bool) async throws -> Void = { _, _, _ in }

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Where to seek after a re-run: the time of the same fact seq when the program is unchanged
    /// and the new trace has that seq; nil otherwise (the stage keeps its time).
    static func seekTarget(previous: LoadedRun?, seq: Int?, newProgramKey: String, newTrace: TraceIndex) -> Double? {
        guard let previous, previous.programKey == newProgramKey, let seq else { return nil }
        return newTrace.timeOfSeq(seq)
    }

    func trigger(_ trigger: Trigger, request: Request) {
        generation += 1
        let gen = generation
        task?.cancel()
        let delay: Duration? = trigger == .fileChange ? debounce : nil
        task = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.execute(request, generation: gen)
        }
    }

    /// Returns when no run is scheduled or in flight (a newer trigger replaces the one waited on).
    func settled() async {
        var last: Task<Void, Never>?
        while let t = task, t != last {
            last = t
            await t.value
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        isRunning = false
    }

    private func execute(_ request: Request, generation gen: Int) async {
        guard gen == generation else { return }
        isRunning = true
        let outcome: RunOutcome
        do {
            outcome = try await request.runner.run(program: request.program, options: request.options)
        } catch {
            guard gen == generation else { return }
            fail(error.localizedDescription, diagnostics: nil, raw: nil)
            return
        }
        guard gen == generation, !Task.isCancelled else { return }
        switch outcome {
        case .diagnostics(let report):
            fail(nil, diagnostics: report, raw: nil)
        case .rawProblems(let text):
            fail(nil, diagnostics: nil, raw: text)
        case .ran(let status, let sceneText, let scene, let trace):
            let run = LoadedRun(programKey: request.programKey, sceneText: sceneText, scene: scene, trace: trace,
                                status: status, options: request.options)
            let sameProgram = loaded?.programKey == request.programKey
            let seek = request.preserveTime ? nil
                : Self.seekTarget(previous: loaded, seq: currentSeq(), newProgramKey: request.programKey, newTrace: trace)
            do {
                try await apply(run, seek, sameProgram)
            } catch {
                guard gen == generation else { return }
                fail("The scene could not be loaded: \(error.localizedDescription)", diagnostics: nil, raw: nil)
                return
            }
            guard gen == generation else { return }
            loaded = run
            stale = false
            diagnostics = nil
            rawProblems = nil
            errorMessage = nil
            isRunning = false
        }
    }

    private func fail(_ message: String?, diagnostics: CheckReport?, raw: String?) {
        self.diagnostics = diagnostics
        rawProblems = raw
        errorMessage = message
        stale = loaded != nil
        isRunning = false
    }
}
