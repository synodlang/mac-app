import Foundation
import Testing

@testable import SynodCore

func loadScope() throws -> DocReport {
    try DocReport.parse(try Fixtures.data("doc/scope-twopc.json"))
}

@Test func docScopeDecodesAndIgnoresUnknownKeys() throws {
    let r = try loadScope()
    #expect(r.scope?.file == "twopc/twopc.synod")
    #expect(r.scope?.imports.map(\.qualifier) == ["net", "time", "r"])
    #expect(r.ownPackage?.name == "twopc")
    #expect(r.importedPackages.map(\.path) == ["std/net", "std/time", "github.com/synodlang/examples/raft"])
    let send = r.packages[1].phrases[0]
    #expect(send.pattern == "net.Send [m: msg] from [a: node] to [b: node]")
    #expect(send.contexts == ["node"])
    #expect(send.items.count == 6)
    #expect(r.packages[0].node?.fields.map(\.name) == ["State", "votes"])
    #expect(r.packages[0].phrases[3].receiver == DocReport.Receiver(name: "n", type: "Node"))
}

@Test func docReportWithDiagnosticsAndFormats() throws {
    let r = try DocReport.parse(try Fixtures.data("doc/with-diagnostics.json"))
    #expect(r.diagnostics.count == 1)
    #expect(r.scope == nil)
    #expect(r.ownPackage == nil)
    #expect(throws: FormatError.self) { try DocReport.parse(try Fixtures.data("doc/future-format.json")) }
    #expect(throws: FormatError.self) { try DocReport.parse(Data("{".utf8)) }
}

@Test func docRunnerArguments() {
    #expect(DocRunner.arguments(file: "a/b.synod", overlay: nil) == ["doc", "--json", "--scope", "a/b.synod"])
    let o = URL(fileURLWithPath: "/tmp/o.json")
    #expect(DocRunner.arguments(file: "a/b.synod", overlay: o) == ["doc", "--json", "--scope", "a/b.synod", "--overlay", "/tmp/o.json"])
}

@Test func scopeCacheKeepsLastGoodScope() throws {
    var cache = ScopeCache()
    let good = try loadScope()
    let bad = try DocReport.parse(try Fixtures.data("doc/with-diagnostics.json"))
    #expect(cache.apply(.diagnostics(bad), file: "a.synod") == nil)
    #expect(cache.apply(.scope(good), file: "a.synod") == good)
    #expect(cache.apply(.diagnostics(bad), file: "a.synod") == good)
    #expect(cache.scope(for: "b.synod") == nil)
}

/// Runs the doc runner with a shell stub that prints a fixture document.
@Test func docRunnerRunsAndMapsExitCodes() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("module example.com/m\nsynod 0.2\n".utf8).write(to: dir.appendingPathComponent("synod.mod"))
    let work = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let script = work.appendingPathComponent("stub.sh")
    let args = work.appendingPathComponent("args.txt")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$@" > '\(args.path)'
    cat '\(Fixtures.url("doc/scope-twopc.json").path)'
    exit ${STUB_EXIT:-0}
    """.utf8).write(to: script)
    let runner = SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: [script.path], environment: ["STUB_EXIT": "0"])
    let ws = try Workspace.open(dir)
    let cache = CachePaths(cacheRoot: work.appendingPathComponent("cache"), supportRoot: work.appendingPathComponent("support"))
    let doc = DocRunner(workspace: ws, runner: runner, cache: cache)
    let out = try await doc.scope(file: "twopc/twopc.synod")
    guard case .scope(let r) = out else { Issue.record("expected scope"); return }
    #expect(r.packages.count == 4)
    #expect(try String(contentsOf: args, encoding: .utf8) == "doc\n--json\n--scope\ntwopc/twopc.synod\n")
    _ = try await doc.scope(file: "twopc/twopc.synod", buffers: ["twopc/twopc.synod": "# package twopc\n"])
    let lines = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.prefix(4) == ["doc", "--json", "--scope", "twopc/twopc.synod"])
    #expect(lines.count == 6 && lines[4] == "--overlay" && lines[5].hasSuffix("overlay.json"))

    let failing = DocRunner(workspace: ws,
                            runner: SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: [script.path], environment: ["STUB_EXIT": "1"]),
                            cache: cache)
    guard case .diagnostics = try await failing.scope(file: "twopc/twopc.synod") else { Issue.record("expected diagnostics"); return }
    let broken = DocRunner(workspace: ws,
                           runner: SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: [script.path], environment: ["STUB_EXIT": "2"]),
                           cache: cache)
    await #expect(throws: PipelineError.self) { try await broken.scope(file: "twopc/twopc.synod") }
}

@Test func versionDocSupport() {
    let with = SynodVersion.parse("language 0.2\ncompiler v0.2.6\nformats synod-trace/1 synod-doc/1\n")
    #expect(with.supportsDoc && with.completionNote == nil)
    let without = SynodVersion.parse("language 0.2\ncompiler v0.2.5\nformats synod-trace/1\n")
    #expect(!without.supportsDoc && without.completionNote != nil)
}

@Test func toolPathsFindAgentSkills() throws {
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(ToolPaths(baseURL: base, avoiding: []).agentSkills == nil)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("agent-skills/skills/synod"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: base.appendingPathComponent("agent-skills/skills/synod/SKILL.md"))
    let paths = ToolPaths(baseURL: base, avoiding: [])
    #expect(paths.agentSkills?.lastPathComponent == "agent-skills")
}
