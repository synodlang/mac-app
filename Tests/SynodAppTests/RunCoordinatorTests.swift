import Foundation
import Testing
import SynodCore
@testable import SynodApp

private let sceneJSON = """
{"format":"synod-scene/1","duration":1000,"canvas":{"w":100,"h":100},"markers":[],"trace":[{"seq":1,"at":0},{"seq":2,"at":100},{"seq":3,"at":400},{"seq":4,"at":900}],"shapes":[]}
"""

private func makeOutcome(seqAts: [(Int, Double)] = [(1, 0), (2, 100), (3, 400), (4, 900)]) throws -> RunOutcome {
    let entries = seqAts.map { #"{"seq":\#($0.0),"at":\#($0.1)}"# }.joined(separator: ",")
    let scene = try SceneSummary.parse(
        #"{"format":"synod-scene/1","duration":1000,"canvas":{"w":100,"h":100},"markers":[],"trace":[\#(entries)],"shapes":[]}"#)
    var lines = [#"{"format":"synod-trace/1","synod":"0.2","seed":1,"program":"p","packages":["p"]}"#]
    for (seq, _) in seqAts { lines.append(#"{"seq":\#(seq),"t":\#(seq * 1000),"ev":"sim.Fired"}"#) }
    let trace = try Trace.parse(Data(lines.joined(separator: "\n").utf8))
    return .ran(status: RunStatus.parse(""), sceneText: sceneJSON, scene: scene, trace: TraceIndex(trace: trace, scene: scene))
}

private final class FakeRunner: ProgramRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var delays: [Duration] = []
    var outcomes: [() throws -> RunOutcome] = []

    var calls: Int { lock.withLock { _calls } }

    func run(program: Workspace.Program, options: RunOptions) async throws -> RunOutcome {
        let n = lock.withLock { () -> Int in _calls += 1; return _calls - 1 }
        if n < delays.count { try? await Task.sleep(for: delays[n]) }
        let make = n < outcomes.count ? outcomes[n] : outcomes.last!
        return try make()
    }
}

private func request(_ runner: FakeRunner, key: String = "m|p") -> RunCoordinator.Request {
    .init(program: Workspace.Program(relPath: "p", mainFile: "main.synod"), programKey: key, options: RunOptions(), runner: runner)
}

@MainActor private final class Applied {
    var runs: [(seek: Double?, keepTime: Bool)] = []
}

@MainActor @Suite struct RunCoordinatorTests {
    @Test func fiveFileChangesInAHundredMillisecondsMakeOneRun() async throws {
        let runner = FakeRunner()
        runner.outcomes = [{ try makeOutcome() }]
        let c = RunCoordinator()
        let applied = Applied()
        c.apply = { _, seek, keep in applied.runs.append((seek, keep)) }
        for _ in 0..<5 {
            c.trigger(.fileChange, request: request(runner))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(700))
        #expect(runner.calls == 1)
        #expect(applied.runs.count == 1)
        #expect(c.loaded != nil)
        #expect(!c.stale)
    }

    @Test func staleGenerationsAreDropped() async throws {
        let runner = FakeRunner()
        runner.delays = [.milliseconds(400), .milliseconds(10)]
        runner.outcomes = [{ try makeOutcome(seqAts: [(1, 0)]) }, { try makeOutcome() }]
        let c = RunCoordinator()
        let applied = Applied()
        c.apply = { _, seek, keep in applied.runs.append((seek, keep)) }
        c.trigger(.manual, request: request(runner))
        try await Task.sleep(for: .milliseconds(50))
        c.trigger(.manual, request: request(runner))
        try await Task.sleep(for: .milliseconds(700))
        #expect(runner.calls == 2)
        #expect(applied.runs.count == 1)
        #expect(c.loaded?.trace.entries.count == 4)
    }

    @Test func keepsTheCurrentFactAcrossRerunsOfTheSameProgram() async throws {
        let runner = FakeRunner()
        // First run: seq 3 at 400. Second run: seq 3 at 450.
        runner.outcomes = [{ try makeOutcome() }, { try makeOutcome(seqAts: [(1, 0), (2, 200), (3, 450), (4, 900)]) }]
        let c = RunCoordinator()
        let applied = Applied()
        c.apply = { _, seek, keep in applied.runs.append((seek, keep)) }
        c.currentSeq = { 3 }
        c.trigger(.manual, request: request(runner))
        try await Task.sleep(for: .milliseconds(200))
        c.trigger(.mode, request: request(runner))
        try await Task.sleep(for: .milliseconds(200))
        #expect(applied.runs.count == 2)
        #expect(applied.runs[0].seek == nil)
        #expect(applied.runs[1].seek == 450)
        #expect(applied.runs[1].keepTime)
    }

    @Test func seekTargetNeedsSameProgramAndExistingSeq() throws {
        guard case .ran(let status, let text, let scene, let trace) = try makeOutcome() else { return }
        let prev = LoadedRun(programKey: "a", sceneText: text, scene: scene, trace: trace, status: status, options: RunOptions())
        #expect(RunCoordinator.seekTarget(previous: prev, seq: 2, newProgramKey: "a", newTrace: trace) == 100)
        #expect(RunCoordinator.seekTarget(previous: prev, seq: 2, newProgramKey: "b", newTrace: trace) == nil)
        #expect(RunCoordinator.seekTarget(previous: prev, seq: 99, newProgramKey: "a", newTrace: trace) == nil)
        #expect(RunCoordinator.seekTarget(previous: prev, seq: nil, newProgramKey: "a", newTrace: trace) == nil)
        #expect(RunCoordinator.seekTarget(previous: nil, seq: 2, newProgramKey: "a", newTrace: trace) == nil)
    }

    @Test func failedRerunKeepsTheGoodRunAndMarksItStale() async throws {
        let runner = FakeRunner()
        runner.outcomes = [{ try makeOutcome() }, { .rawProblems("boom") }]
        let c = RunCoordinator()
        c.apply = { _, _, _ in }
        c.trigger(.manual, request: request(runner))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!c.stale)
        c.trigger(.manual, request: request(runner))
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.stale)
        #expect(c.loaded != nil)
        #expect(c.rawProblems == "boom")
        #expect(!c.isRunning)
    }
}
