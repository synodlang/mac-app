import Foundation
import Testing

@testable import SynodCore

private let skillMarkdown = "---\nname: synod\ndescription: Write Synod.\n---\n\n# Synod\n\nUse rules.\n"

private func invocation(request: String = "animate it", model: String? = nil, session: String? = nil,
                        host: [String: String] = [:]) -> ClaudeInvocation {
    ClaudeInvocation(
        claude: URL(fileURLWithPath: "/Users/u/.local/bin/claude"), request: request,
        workingDirectory: URL(fileURLWithPath: "/work/mod"), mcpConfig: URL(fileURLWithPath: "/tmp/synod-mcp-ab/claude-1.json"),
        skillsFolder: URL(fileURLWithPath: "/skills"), skillMarkdown: skillMarkdown,
        synod: URL(fileURLWithPath: "/App/Contents/Helpers/synod"), model: model, sessionID: session, hostEnvironment: host)
}

private let systemPrompt = "# Synod\n\nUse rules.\n\nThe reference files are in /skills/skills/synod/reference/.\n\n" + ClaudeInvocation.editorPrompt

@Test func firstRequestArgv() {
    #expect(invocation().arguments == [
        "-p", "animate it", "--output-format", "stream-json", "--verbose",
        "--append-system-prompt", systemPrompt,
        "--add-dir", "/skills/skills/synod",
        "--mcp-config", "/tmp/synod-mcp-ab/claude-1.json", "--strict-mcp-config",
        "--allowedTools", "Read,Glob,Grep,mcp__synod-editor__*,mcp__synod__doc,mcp__synod__explain,mcp__synod__check,mcp__synod__run_summary,Bash(synod get:*)",
        "--disallowedTools", "Write,Edit,MultiEdit,NotebookEdit,WebFetch,WebSearch,mcp__synod__fmt",
    ])
}

@Test func modelAndResumeAreAppended() {
    let a = invocation(model: "claude-opus-5-5", session: "sess-1").arguments
    #expect(Array(a.suffix(4)) == ["--model", "claude-opus-5-5", "--resume", "sess-1"])
    #expect(invocation(model: "", session: nil).arguments.contains("--model") == false)
    #expect(invocation(model: "  ", session: "").arguments.contains("--resume") == false)
    #expect(invocation(session: "s").arguments.suffix(2) == ["--resume", "s"])
}

@Test func toolListsExcludeWritingAndShell() {
    let allowed = ClaudeInvocation.allowedTools.split(separator: ",").map(String.init)
    for banned in ["Write", "Edit", "Bash", "WebFetch"] { #expect(!allowed.contains(banned)) }
    #expect(allowed.filter { $0.hasPrefix("Bash") } == ["Bash(synod get:*)"])
    #expect(ClaudeInvocation.disallowedTools.contains("mcp__synod__fmt"))
}

@Test func requestStartingWithDashIsNotAFlag() {
    #expect(invocation(request: "--help").arguments[1] == " --help")
}

@Test func frontMatterIsStripped() {
    #expect(ClaudeInvocation.stripFrontMatter(skillMarkdown) == "# Synod\n\nUse rules.\n")
    #expect(ClaudeInvocation.stripFrontMatter("# No front matter\n") == "# No front matter\n")
    #expect(ClaudeInvocation.stripFrontMatter("---\nunterminated\n") == "---\nunterminated\n")
}

@Test func environmentIsTheAllowlist() {
    let host = ["HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8",
                "LC_ALL": "C", "TMPDIR": "/var/t/", "PATH": "/evil", "ANTHROPIC_API_KEY": "sentinel-key",
                "ANTHROPIC_BASE_URL": "x", "AWS_SECRET_ACCESS_KEY": "sentinel", "NO_COLOR": "0", "TERM": "xterm"]
    let env = invocation(host: host).environment
    #expect(env == [
        "HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TMPDIR": "/var/t/",
        "PATH": "/App/Contents/Helpers:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "NO_COLOR": "1", "TERM": "dumb",
    ])
    #expect(!env.values.contains("sentinel-key") && !env.values.contains("sentinel"))
    // unset allowlisted variables stay unset
    #expect(invocation(host: ["HOME": "/h"]).environment["USER"] == nil)
}

@Test func explainPreset() {
    #expect(ClaudeInvocation.explainRunPrompt(program: "twopc", mainFile: "twopc/demo.synod")
        == "Explain this run: run \"synod run twopc --summary\", then add lesson.Note lines to define main in twopc/demo.synod that caption what happens, at the times it happens. Do not change the behaviour.")
}

// MARK: stream

private func events(_ fixture: String, root: String? = "/work/mod") throws -> [ClaudeEvent] {
    let parser = ClaudeStreamParser(moduleRoot: root.map { URL(fileURLWithPath: $0) })
    return try Fixtures.text("claude/\(fixture)").split(separator: "\n").flatMap { parser.parse(line: String($0)) }
}

@Test func streamSuccess() throws {
    let e = try events("stream-success.jsonl")
    #expect(e.first == .initialized(sessionID: "sess-1", model: "claude-opus-5-5"))
    #expect(e.contains(.text("I will look at the package.")))
    #expect(e.compactMap(\.progressLine) == [
        "Read twopc/twopc.synod", "Edited demo.synod", "Ran synod get github.com/synodlang/examples@v0.2.1",
        "Searched Participants", "Ran synod run twopc", "Saved demo.synod, twopc/twopc.synod",
    ])
    #expect(e.contains(.toolResult(toolUseID: "t1", isError: false)))
    #expect(e.contains(.toolResult(toolUseID: "t2", isError: true)))
    #expect(e.last == .result(isError: false, text: "Done: the coordinator crashes at 45 ms.", sessionID: "sess-1", durationMs: 4210))
}

@Test func streamError() throws {
    let e = try events("stream-error.jsonl")
    guard case .result(let isError, let text, _, _) = e.last else { Issue.record("no result"); return }
    #expect(isError)
    #expect(ClaudeStreamParser.isLoginProblem(text))
    #expect(!ClaudeStreamParser.isLoginProblem("The build failed"))
}

@Test func streamToleratesUnknownEvents() throws {
    let e = try events("stream-unknown.jsonl")
    #expect(e == [.other, .other, .text("Hello"), .result(isError: false, text: "ok", sessionID: nil, durationMs: nil)])
}

@Test func progressLinesForMCPTools() {
    #expect(ClaudeProgress.line(tool: "mcp__synod-editor__create_file", summary: "new/new.synod") == "Created new/new.synod")
    #expect(ClaudeProgress.line(tool: "mcp__synod-editor__get_diagnostics", summary: "demo.synod") == "Checked demo.synod")
    #expect(ClaudeProgress.line(tool: "mcp__synod-editor__list_files", summary: "") == "Listed files")
    #expect(ClaudeProgress.line(tool: "mcp__synod__explain", summary: "unknown-phrase") == "Ran synod explain unknown-phrase")
    #expect(ClaudeProgress.line(tool: "Bash", summary: "synod check .") == "Ran synod check .")
    #expect(ClaudeProgress.line(tool: "Mystery", summary: "") == "Mystery")
}

// MARK: locator

@Test func locatorPrefersSettingThenCandidates() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(ClaudeLocator.candidates(home: home.path).map(\.path) == [
        home.path + "/.local/bin/claude", home.path + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    let fake = home.appendingPathComponent(".claude/local/claude")
    try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho '1.2.3 (Claude Code)'\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    #expect(ClaudeLocator.detect(home: home.path, candidates: [home.appendingPathComponent("nope"), fake]) == fake)
    #expect(ClaudeLocator.resolve(setting: fake.path) == fake)
    #expect(ClaudeLocator.resolve(setting: home.path + "/missing") == nil)
}

@Test func locatorReadsVersionWithin5Seconds() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let ok = dir.appendingPathComponent("claude-ok")
    try Data("#!/bin/sh\necho '1.2.3 (Claude Code)'\n".utf8).write(to: ok)
    let slow = dir.appendingPathComponent("claude-slow")
    try Data("#!/bin/sh\nsleep 20\n".utf8).write(to: slow)
    for f in [ok, slow] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
    let synod = URL(fileURLWithPath: "/x/synod")
    #expect(await ClaudeLocator.version(of: ok, synod: synod) == "1.2.3 (Claude Code)")
    let start = ContinuousClock.now
    #expect(await ClaudeLocator.version(of: slow, synod: synod, timeout: .milliseconds(300)) == nil)
    #expect(ContinuousClock.now - start < .seconds(5))
}

// MARK: process (a shell stub that only echoes stream-json; T12's fake-claude replaces it later)

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func processStreamsLinesInOrderWithAllowlistEnvironment() async throws {
    let cwd = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let host = ["HOME": "/h", "ANTHROPIC_API_KEY": "sentinel"]
    let env = ClaudeInvocation.environment(host: host, synod: URL(fileURLWithPath: "/a/synod"), claude: URL(fileURLWithPath: "/b/claude"))
    let proc = ClaudeProcess(executable: Fixtures.url("claude/echo-stream.sh"),
                             arguments: [Fixtures.url("claude/stream-success.jsonl").path], environment: env, workingDirectory: cwd)
    let lines = Lines()
    let exit = try await proc.run { lines.add($0) }
    #expect(exit.status == 0 && !exit.stopped && !exit.timedOut)
    let expected = try Fixtures.text("claude/stream-success.jsonl").split(separator: "\n").map(String.init)
    #expect(lines.all == expected)
    #expect(exit.stderr.contains("cwd=" + cwd.path))
    // only the allowlist (HOME, PATH, NO_COLOR, TERM) plus whatever /bin/sh adds itself (PWD, SHLVL, _)
    let count = Int(exit.stderr.split(separator: "\n").first { $0.hasPrefix("env=") }!.dropFirst(4))!
    #expect(count <= env.count + 4)
}

@Test func processStopEscalatesFromSigint() async throws {
    let cwd = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let proc = ClaudeProcess(executable: Fixtures.url("claude/echo-stream.sh"),
                             arguments: ["unused", "slow"], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: cwd)
    let lines = Lines()
    let start = ContinuousClock.now
    async let result = proc.run { lines.add($0) }
    while lines.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    await proc.stop()
    let exit = try await result
    #expect(exit.status == 130 && exit.stopped)
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test func processEscalatesToSigkillWhenSigintIsIgnored() async throws {
    let cwd = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let script = cwd.appendingPathComponent("stubborn.sh")
    try Data("#!/bin/sh\ntrap '' INT TERM\necho ready\nwhile :; do sleep 0.05; done\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let proc = ClaudeProcess(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: cwd,
                             stopTiming: .init(sigtermAfter: .milliseconds(200), sigkillAfter: .milliseconds(200)))
    let lines = Lines()
    async let result = proc.run { lines.add($0) }
    while lines.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    await proc.stop()
    let exit = try await result
    #expect(exit.stopped && exit.status == SIGKILL)
}

@Test func processTimeoutStopsIt() async throws {
    let cwd = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let proc = ClaudeProcess(executable: Fixtures.url("claude/echo-stream.sh"), arguments: ["unused", "slow"],
                             environment: ["PATH": "/usr/bin:/bin"], workingDirectory: cwd, timeout: .milliseconds(300))
    let exit = try await proc.run { _ in }
    #expect(exit.timedOut && exit.status == 130)
}

@Test func processLaunchFailure() async throws {
    let proc = ClaudeProcess(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [], environment: [:],
                             workingDirectory: FileManager.default.temporaryDirectory)
    await #expect(throws: RunnerError.self) { try await proc.run { _ in } }
}
