import Foundation
import Testing

@testable import SynodCore

// MARK: Workspace

@Test func scanMiniModule() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try makeMiniModule(in: dir)
    let ws = try Workspace.open(dir)
    #expect(ws.modulePath == "example.com/mini")
    #expect(ws.languageVersion == "0.2")
    let scan = ws.scan()
    #expect(scan.programs.count == 9)
    #expect(scan.programs.map(\.relPath) == ["cassandra", "gossip", "paxos", "raft", "ring", "tcp", "twopc", "wal", "webapp"])
    #expect(scan.programs.allSatisfy { $0.mainFile == "demo.synod" })
    #expect(scan.packages.map(\.relPath) == ["raftlook", "ringlook"])
    #expect(scan.packages[0].files == ["raftlook.synod"])
}

@Test func scanSkipsHiddenAndSpecialFolders() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("module m\nsynod 0.2\nrequire example.com/x v1.0.0\n", to: dir.appendingPathComponent("synod.mod"))
    try write("# package main\n", to: dir.appendingPathComponent("a/main.synod"))
    try write("# package b\n", to: dir.appendingPathComponent("b/b.synod"))
    try write("# package main\n", to: dir.appendingPathComponent("nested/deep/c/main.synod"))
    for skipped in [".hidden", "_tmp", "testdata", "vendor/x@v1", "out", "a/out", ".git/hooks"] {
        try write("# package main\n", to: dir.appendingPathComponent("\(skipped)/main.synod"))
    }
    try write("# package main\n", to: dir.appendingPathComponent("a/.dot.synod"))
    try write("no header\n# package main\n", to: dir.appendingPathComponent("noheader/x.synod"))
    try write("\u{FEFF}# package main\r\n", to: dir.appendingPathComponent("bom/x.synod"))
    try write("hello", to: dir.appendingPathComponent("notes/readme.txt"))
    let ws = try Workspace.open(dir)
    #expect(ws.requires == ["example.com/x v1.0.0"])
    let scan = ws.scan()
    #expect(scan.programs.map(\.relPath) == ["a", "bom", "nested/deep/c"])
    #expect(scan.packages.map(\.relPath) == ["b", "noheader"])
}

@Test func openWalksUpToSynodMod() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try makeMiniModule(in: dir)
    let file = dir.appendingPathComponent("raft/demo.synod")
    #expect(FileWatcher.realPath(try Workspace.open(file).root.path) == dir.path)
    #expect(FileWatcher.realPath(try Workspace.open(dir.appendingPathComponent("raft")).root.path) == dir.path)
}

@Test func openFailsWithoutSynodMod() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("# package main\n", to: dir.appendingPathComponent("p/main.synod"))
    #expect(throws: Workspace.OpenError.notAWorkspace) { try Workspace.open(dir.appendingPathComponent("p")) }
    #expect(Workspace.OpenError.notAWorkspace.errorDescription == "Not a Synod workspace (no synod.mod)")
}

@Test(.enabled(if: ToolPaths.repoDeps() != nil, ".deps is not filled; run scripts/fetch-deps.sh"))
func scanRealExamples() throws {
    let tools = try #require(ToolPaths.repoDeps())
    let ws = try Workspace.open(try #require(tools.examples))
    let scan = ws.scan()
    #expect(scan.programs.count == 9)
    let names = scan.packages.map(\.relPath)
    #expect(names.contains("raftlook") && names.contains("ringlook"))
    // webapp is a program whose sub-folders are its packages.
    #expect(names.filter { $0.hasPrefix("webapp/") }.count == names.count - 2)
    #expect(ws.modulePath == "github.com/synodlang/examples")
}

@Test func toolPathsLayouts() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // App bundle layout: Contents/Helpers/synod and Contents/Resources/examples.
    let helpers = dir.appendingPathComponent("Synod.app/Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let bin = helpers.appendingPathComponent("synod")
    try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    let res = dir.appendingPathComponent("Synod.app/Contents/Resources")
    try FileManager.default.createDirectory(at: res.appendingPathComponent("examples"), withIntermediateDirectories: true)
    let tools = ToolPaths(baseURL: res)
    #expect(FileWatcher.realPath(tools.synod.path) == FileWatcher.realPath(bin.path))
    #expect(tools.examples?.lastPathComponent == "examples")
    #expect(tools.isUsable)
    #expect(tools.overriding(synodPath: "").synod == tools.synod)
    #expect(tools.overriding(synodPath: "/opt/synod").synod.path == "/opt/synod")
}

// MARK: SynodRunner

@Test func runnerReturnsExitCodesAndOutput() async throws {
    let ok = try await fakeRunner("ok").exec(["check", "--json", "p"], cwd: FileManager.default.temporaryDirectory)
    #expect(ok.exitCode == 0)
    #expect(ok.stdoutText.contains("synod-check/1"))

    let diag = try await fakeRunner("diag").exec(["check", "--json", "p"], cwd: FileManager.default.temporaryDirectory)
    #expect(diag.exitCode == 1)
    #expect(try CheckReport.parse(diag.stdout).hasErrors)

    let tool = try await fakeRunner("tool-error").exec(["check"], cwd: FileManager.default.temporaryDirectory)
    #expect(tool.exitCode == 2)
    #expect(tool.stderrText.contains("usage error"))
}

@Test func runnerReadsBothStreamsFully() async throws {
    let r = try await fakeRunner("big", timeout: .seconds(20)).exec(["run"], cwd: FileManager.default.temporaryDirectory)
    #expect(r.exitCode == 0)
    #expect(r.stdout.count == 1024 * 1024)
    #expect(r.stderr.count == 1024 * 1024)
}

@Test func runnerSetsNoColorAndCwd() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: ["-c", "echo \"$NO_COLOR $FOO $(pwd -P)\""], environment: ["FOO": "bar"])
    let r = try await runner.exec([], cwd: dir)
    #expect(r.stdoutText == "1 bar \(dir.path)\n")
}

@Test func runnerLaunchFailure() async {
    let runner = SynodRunner(executable: URL(fileURLWithPath: "/nonexistent/synod"))
    await #expect(throws: RunnerError.self) { try await runner.exec(["version"], cwd: FileManager.default.temporaryDirectory) }
}

@Test func runnerCancellationKillsQuickly() async throws {
    let runner = fakeRunner("sleep")
    let task = Task { try await runner.exec(["run", "p"], cwd: FileManager.default.temporaryDirectory) }
    try await Task.sleep(for: .milliseconds(400))
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    // The fake sleeps 30 s, so finishing well before that proves the kill; the
    // bound is loose because CI runners are slow while tests run in parallel.
    #expect(ContinuousClock.now - start < .seconds(20))
}

@Test func runnerTimesOut() async throws {
    let runner = fakeRunner("sleep", timeout: .seconds(1))
    let start = ContinuousClock.now
    await #expect(throws: RunnerError.timedOut(seconds: 1)) { try await runner.exec(["run"], cwd: FileManager.default.temporaryDirectory) }
    // The fake sleeps 30 s, so finishing well before that proves the kill; the
    // bound is loose because CI runners are slow while tests run in parallel.
    #expect(ContinuousClock.now - start < .seconds(20))
}

@Test func probeReadsTheVersion() async throws {
    let v = try await SynodVersion.probe(fakeRunner("ok"))
    #expect(v.isCompatible)
    #expect(v.language == "0.2")
}

// MARK: RunPipeline

private struct PipelineFixture {
    let dir: URL
    let workspace: Workspace
    let cache: CachePaths
    let argsFile: URL
    let program: Workspace.Program

    init() throws {
        dir = try makeTempDir()
        let module = dir.appendingPathComponent("module")
        _ = try makeMiniModule(in: module)
        workspace = try Workspace.open(module)
        cache = CachePaths.under(dir)
        argsFile = dir.appendingPathComponent("args.txt")
        program = workspace.scan().programs.first { $0.relPath == "raft" }!
    }

    func pipeline(_ mode: String) -> RunPipeline {
        RunPipeline(workspace: workspace, runner: fakeRunner(mode, argsFile: argsFile), cache: cache)
    }

    var calls: [String] { ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Test func pipelineRunsAndLoadsEverything() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    let outcome = try await fx.pipeline("ok").run(program: fx.program, options: RunOptions(mode: .proportional, seed: 3))
    guard case .ran(let status, let sceneText, let scene, let trace) = outcome else { Issue.record("not ran: \(outcome)"); return }
    #expect(status.fault == nil)
    if case .ok(let seed, _, _, _, let events, _) = try #require(status.result) { #expect(seed == 3 && events == 2197) }
    #expect(sceneText.hasPrefix(#"{"format":"synod-scene/1""#))
    #expect(scene.duration == 147982)
    #expect(trace.events.count == 2197)
    #expect(trace.header.seed == 3)

    let calls = fx.calls
    #expect(calls.count == 2)
    #expect(calls[0] == "check --json --tokens raft")
    #expect(calls[1].hasPrefix("run raft --mode proportional --seed 3 --trace "))
    #expect(calls[1].contains(" --style short --color never"))
    #expect(calls[1].contains(fx.cache.cacheRoot.path), "outputs go to the cache")
    #expect(!FileManager.default.fileExists(atPath: fx.workspace.root.appendingPathComponent("out").path), "nothing is written to the workspace")
}

@Test func pipelineOmitsSeedByDefault() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    _ = try await fx.pipeline("ok").run(program: fx.program)
    #expect(!fx.calls[1].contains("--seed"))
    #expect(fx.calls[1].contains("--mode ordered"))
}

@Test func pipelineStopsAtDiagnostics() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    let outcome = try await fx.pipeline("diag").run(program: fx.program)
    guard case .diagnostics(let report) = outcome else { Issue.record("not diagnostics"); return }
    #expect(report.hasErrors)
    #expect(report.diagnostics.first?.code == "type-mismatch")
    #expect(fx.calls == ["check --json --tokens raft"], "run must not start after errors")
}

@Test func failedRunStillProducesAnOutcomeWithAScene() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    guard case .ran(let status, let sceneText, let scene, let trace) = try await fx.pipeline("fail").run(program: fx.program) else {
        Issue.record("expected .ran")
        return
    }
    #expect(status.fault?.code == "time-limit")
    #expect(status.fault?.pos == nil)
    #expect(!sceneText.isEmpty)
    #expect(scene.duration > 0)
    #expect(trace.events.last?.ev == "sim.Failed")
}

@Test func lookFailureStillLoadsTheScene() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    guard case .ran(let status, _, let scene, let trace) = try await fx.pipeline("lookfail").run(program: fx.program) else {
        Issue.record("expected .ran")
        return
    }
    #expect(status.fault == nil)
    #expect(status.lookFault?.code == "missing-key")
    #expect(scene.trace.count == trace.events.count)
}

@Test func brokenRulesAreReported() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    guard case .ran(let status, _, _, _) = try await fx.pipeline("broken").run(program: fx.program) else {
        Issue.record("expected .ran")
        return
    }
    #expect(status.broken.map(\.count) == [2])
}

@Test func runWithoutFilesShowsRawText() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    guard case .rawProblems(let text) = try await fx.pipeline("no-files").run(program: fx.program) else {
        Issue.record("expected raw problems")
        return
    }
    #expect(text.contains("error[missing-main]"))
}

@Test func toolErrorsThrow() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    await #expect(throws: PipelineError.self) { try await fx.pipeline("tool-error").run(program: fx.program) }
}

@Test func runFoldersKeepTheLastTwo() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    let pipe = fx.pipeline("ok")
    for _ in 0..<4 { _ = try await pipe.run(program: fx.program) }
    let base = fx.cache.programRunsFolder(moduleRoot: fx.workspace.root, program: "raft")
    let runs = CachePaths.generations(in: base).map(\.0).sorted()
    #expect(runs == [3, 4])
    #expect(base.lastPathComponent.count == 16)
}

@Test func cancelledPipelineThrowsCancellation() async throws {
    let fx = try PipelineFixture()
    defer { fx.cleanup() }
    let pipe = RunPipeline(workspace: fx.workspace, runner: fakeRunner("sleep"), cache: fx.cache)
    let task = Task { try await pipe.run(program: fx.program) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

@Test(.enabled(if: ToolPaths.repoDeps() != nil, ".deps is not filled; run scripts/fetch-deps.sh"))
func realSynodRunsRaft() async throws {
    let tools = try #require(ToolPaths.repoDeps())
    let ws = try Workspace.open(try #require(tools.examples))
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = SynodRunner(executable: tools.synod)
    let version = try await SynodVersion.probe(runner)
    #expect(version.isCompatible, "\(version)")
    let raft = try #require(ws.scan().programs.first { $0.relPath == "raft" })
    let pipeline = RunPipeline(workspace: ws, runner: runner, cache: CachePaths.under(dir))
    let outcome = try await pipeline.run(program: raft, options: RunOptions(mode: .ordered))
    guard case .ran(let status, let sceneText, let scene, let trace) = outcome else { Issue.record("not ran: \(outcome)"); return }
    guard case .ok(let seed, let reason, let end, let nodes, let events, _) = try #require(status.result) else { Issue.record("not ok"); return }
    #expect(seed == 3 && reason == "stop" && end == SimTime(microseconds: 8_000_000) && nodes == 5 && events == 2197)
    #expect(trace.events.count == 2197)
    #expect(trace.header.seed == 3)
    #expect(scene.duration == 147982)
    #expect(scene.trace.count == 2197)
    #expect(sceneText.count > 100_000)
    if case .ok(let length, _, _) = try #require(status.scene) { #expect(length == "147.98s") }
    // The real trace gives the same replay as the committed fixture.
    #expect(trace.events.map(\.seq) == Array(1...2197))
    #expect(trace.events.map(\.summaryLine) == (try Fixtures.trace("raft")).events.map(\.summaryLine))
    #expect(!FileManager.default.fileExists(atPath: ws.root.appendingPathComponent("out").path))
}

// MARK: AnswerStore

@Test func answerStoreRoundTrip() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = CachePaths.under(dir)
    let root = dir.appendingPathComponent("mod")
    let store = AnswerStore(moduleRoot: root, program: "raft/demo", paths: paths)
    #expect(store.all().isEmpty)
    #expect(store.fileURL.lastPathComponent == "raft-demo.json")
    #expect(store.fileURL.path.hasPrefix(paths.supportRoot.appendingPathComponent("answers").path))

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = AnswerStore.Entry(question: "Who becomes leader?", answer: "n3", seed: 3, mode: "ordered", date: date)
    try store.save(first)
    try store.save(AnswerStore.Entry(question: "Why?", answer: "term", seed: nil, mode: "proportional", date: date))
    #expect(store.all().count == 2)
    #expect(store.entry(for: "Who becomes leader?") == first)

    let replaced = AnswerStore.Entry(question: "Who becomes leader?", answer: "n1", seed: 4, mode: "ordered", date: date)
    try store.save(replaced)
    #expect(store.all().count == 2)
    #expect(store.entry(for: "Who becomes leader?")?.answer == "n1")
    #expect(store.entry(for: "unknown") == nil)

    // Another program and another module do not share entries.
    #expect(AnswerStore(moduleRoot: root, program: "tcp", paths: paths).all().isEmpty)
    #expect(AnswerStore(moduleRoot: dir.appendingPathComponent("other"), program: "raft/demo", paths: paths).all().isEmpty)
    #expect(AnswerStore(moduleRoot: root, program: ".", paths: paths).fileURL.lastPathComponent == "main.json")
}

// MARK: FileWatcher

@Test func watcherReportsSynodWritesAndIgnoresOutAndDotFolders() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("module m\nsynod 0.2\n", to: dir.appendingPathComponent("synod.mod"))
    try write("# package main\n", to: dir.appendingPathComponent("p/main.synod"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)

    // Let the setup writes settle so FSEvents does not report them to the new stream.
    try await Task.sleep(for: .milliseconds(1200))
    let watcher = FileWatcher(root: dir)
    let seen = Collector<Set<String>>()
    let reader = Task { for await batch in watcher.events { seen.add(batch) } }
    defer { reader.cancel(); watcher.stop() }
    try await Task.sleep(for: .milliseconds(500))

    // Ignored paths first: no event may arrive.
    try write("x", to: dir.appendingPathComponent("out/trace.jsonl"))
    try write("# package main\n", to: dir.appendingPathComponent("out/x.synod"))
    try write("x", to: dir.appendingPathComponent(".git/y.synod"))
    try write("notes", to: dir.appendingPathComponent("p/notes.txt"))
    try await Task.sleep(for: .milliseconds(900))
    #expect(seen.values.isEmpty, "got \(seen.values)")

    let start = ContinuousClock.now
    try write("# package main\nuse m/x\n", to: dir.appendingPathComponent("p/main.synod"))
    let got = await waitUntil(timeout: 2) { seen.values.contains { $0.contains("p/main.synod") } }
    #expect(got, "no event for p/main.synod within 2 s")
    #expect(ContinuousClock.now - start < .seconds(2))

    try write("module m\nsynod 0.2\nrequire a v1\n", to: dir.appendingPathComponent("synod.mod"))
    #expect(await waitUntil(timeout: 2) { seen.values.contains { $0.contains("synod.mod") } })
}

@Test func watcherRelevanceRules() {
    #expect(FileWatcher.isRelevant("a/b.synod"))
    #expect(FileWatcher.isRelevant("synod.mod"))
    #expect(FileWatcher.isRelevant("vendor/x@v1/y.synod"))
    #expect(FileWatcher.isRelevant("vendor/x@v1/synod.mod"))
    #expect(!FileWatcher.isRelevant("out/scene.json"))
    #expect(!FileWatcher.isRelevant("out/b.synod"))
    #expect(!FileWatcher.isRelevant(".git/b.synod"))
    #expect(!FileWatcher.isRelevant("a/.hidden/b.synod"))
    #expect(!FileWatcher.isRelevant("a/notes.txt"))
    #expect(!FileWatcher.isRelevant("a/synod.mod"))
}
