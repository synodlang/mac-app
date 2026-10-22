import Foundation
import Testing

@testable import SynodCore

struct MCPTokenTests {
    @Test func generatedTokensAreSixtyFourHexAndDiffer() throws {
        let a = try MCPTokens.generate(), b = try MCPTokens.generate()
        #expect(BridgeHandshake.isValidToken(a) && a == a.lowercased())
        #expect(a != b)
    }

    @Test func constantTimeCompare() {
        let t = String(repeating: "ab", count: 32)
        #expect(BridgeHandshake.constantTimeEquals(t, t))
        #expect(!BridgeHandshake.constantTimeEquals(t, String(t.dropLast()) + "c"))
        #expect(!BridgeHandshake.constantTimeEquals(t, "c" + t.dropFirst()))
        #expect(!BridgeHandshake.constantTimeEquals(t, String(t.dropLast())))
        #expect(!BridgeHandshake.constantTimeEquals(t, t + "a"))
        #expect(BridgeHandshake.constantTimeEquals("", ""))
        #expect(!BridgeHandshake.constantTimeEquals("", "a"))
    }

    @Test func handshakeLineRoundTrips() throws {
        let t = try MCPTokens.generate()
        let h = BridgeHandshake(token: t, workspace: "/a b/\"c\"")
        #expect(BridgeHandshake.parse(line: h.line) == h)
        #expect(BridgeHandshake(token: t, workspace: nil).line == #"{"synodEditorBridge":1,"token":"\#(t)","workspace":null}"#)
        #expect(BridgeHandshake.parse(line: BridgeHandshake(token: t, workspace: nil).line)?.workspace == nil)
        #expect(BridgeHandshake.parse(line: #"{"synodEditorBridge":2,"token":"\#(t)","workspace":null}"#) == nil)
        #expect(BridgeHandshake.parse(line: #"{"synodEditorBridge":1,"token":"short","workspace":null}"#) == nil)
        #expect(BridgeHandshake.parse(line: "nope") == nil)
    }

    @Test func tokenTableChecksEveryTokenAndRevokes() async throws {
        let table = TokenTable()
        let t1 = try MCPTokens.generate(), t2 = try MCPTokens.generate()
        let grant = BridgeGrant(tools: EditorToolRegistry(service: MockEditor()), serverVersion: "1")
        await table.add(token: t1, grant: grant)
        await table.add(token: t2) { ws in ws == "/root" ? grant : nil }
        #expect(await table.authorize(BridgeHandshake(token: t1, workspace: nil)) != nil)
        #expect(await table.authorize(BridgeHandshake(token: t2, workspace: "/root")) != nil)
        #expect(await table.authorize(BridgeHandshake(token: t2, workspace: "/other")) == nil)
        #expect(await table.authorize(BridgeHandshake(token: t2, workspace: nil)) == nil)
        await table.revoke(token: t1)
        #expect(await table.authorize(BridgeHandshake(token: t1, workspace: nil)) == nil)
        await table.revokeAll()
        #expect(await table.count == 0)
    }
}

struct MCPListenerTests {
    func handshake(_ s: TestSocket, token: String, workspace: String? = nil) {
        s.send(BridgeHandshake(token: token, workspace: workspace).line)
    }

    @Test func permissionsSessionAndCleanup() async throws {
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let editor = MockEditor()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: editor), baseDirectory: base)
        #expect(await listener.isListening == false)
        let sock = try await listener.acquire()
        let folder = try #require(await listener.folderURL)
        #expect(posixMode(folder.path) == 0o700)
        #expect(posixMode(sock.path) == 0o600)
        #expect(folder.lastPathComponent.hasPrefix("synod-mcp-") && folder.lastPathComponent.count == "synod-mcp-".count + 8)
        #expect(sock.lastPathComponent == "editor.sock")
        #expect(sock.path.utf8.count < 104)

        let c = try #require(TestSocket(path: sock.path))
        handshake(c, token: token)
        #expect(await c.readLine() == #"{"ok":true}"#)
        c.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let init1 = try JSONParser.parse(try #require(await c.readLine()))
        #expect(init1["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        c.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_files","arguments":{}}}"#)
        let r = try JSONParser.parse(try #require(await c.readLine()))
        #expect(r["result"]?["structuredContent"]?["files"]?.arrayValue?.count == 1)

        // a second holder keeps it alive
        try await listener.acquire()
        await listener.release()
        #expect(await listener.isListening)
        c.close()
        await listener.release()
        #expect(await listener.isListening == false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: sock.path))
        #expect(TestSocket(path: sock.path) == nil)
    }

    @Test func wrongTokenAndBadHandshakeCloseTheConnection() async throws {
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: MockEditor()), baseDirectory: base)
        let sock = try await listener.acquire()
        let wrong = try #require(TestSocket(path: sock.path))
        handshake(wrong, token: String(token.dropLast()) + (token.last == "a" ? "b" : "a"))
        #expect(await wrong.readLine() == nil)
        let garbage = try #require(TestSocket(path: sock.path))
        garbage.send("hello")
        #expect(await garbage.readLine() == nil)
        let early = try #require(TestSocket(path: sock.path))
        early.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(await early.readLine() == nil)
        await listener.release()
    }

    @Test func silentConnectionTimesOut() async throws {
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: try MCPTokens.generate(), editor: MockEditor()), baseDirectory: base, handshakeTimeout: .milliseconds(200))
        let sock = try await listener.acquire()
        let c = try #require(TestSocket(path: sock.path))
        #expect(await c.readLine() == nil)
        await listener.release()
    }

    @Test func closeConnectionsForTokenEndsTheSession() async throws {
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: MockEditor()), baseDirectory: base)
        let sock = try await listener.acquire()
        let c = try #require(TestSocket(path: sock.path))
        handshake(c, token: token)
        #expect(await c.readLine() == #"{"ok":true}"#)
        await listener.closeConnections(token: token)
        #expect(await c.readLine() == nil)
        await listener.release()
    }

    @Test func noIPListener() async throws {
        // The listener is a Unix socket only; no TCP listener exists in this process for it.
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let listener = UnixSocketListener(authority: TokenTable(), baseDirectory: base)
        _ = try await listener.acquire()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", String(getpid()), "-iTCP", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(data.isEmpty)
        await listener.release()
    }
}

struct MCPConfigFileTests {
    @Test func writesModeAndShapeThenDeletes() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let servers = MCPConfigFile.promptBarServers(bridge: "/App/Helpers/synod-editor-mcp", socket: "/tmp/x/editor.sock", token: "tok", synod: "/App/Helpers/synod")
        let file = try MCPConfigFile.write(servers: servers, in: dir)
        #expect(posixMode(file.url.path) == 0o600)
        #expect(file.url.lastPathComponent.hasPrefix("claude-") && file.url.pathExtension == "json")
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(
            text == #"{"mcpServers":{"synod-editor":{"type":"stdio","command":"/App/Helpers/synod-editor-mcp","args":["--socket","/tmp/x/editor.sock"],"env":{"SYNOD_EDITOR_TOKEN":"tok"}},"synod":{"type":"stdio","command":"/App/Helpers/synod","args":["mcp"],"env":{}}}}"# + "\n")
        let other = try MCPConfigFile.write(servers: servers, in: dir)
        #expect(other.url != file.url)
        file.remove()
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(FileManager.default.fileExists(atPath: other.url.path))
    }
}

/// Runs a process with piped stdio and a timeout on reads.
final class RunningProcess: @unchecked Sendable {
    let process = Process()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private var buffer = Data()

    init(_ url: URL, _ args: [String], env: [String: String] = [:], inheritEnv: Bool = true) {
        process.executableURL = url
        process.arguments = args
        var e = inheritEnv ? ProcessInfo.processInfo.environment : [:]
        for (k, v) in env { e[k] = v }
        process.environment = e
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run() throws { try process.run() }

    func send(_ line: String) { try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
    func closeStdin() { try? stdin.fileHandleForWriting.close() }

    func readLine() async -> String? {
        await offPool { self.readLineBlocking() }
    }

    private func readLineBlocking() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(stdout.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func waitForExit(timeout: TimeInterval = 10) async -> Int32? {
        await offPool { self.waitBlocking(timeout) }
    }

    private func waitBlocking(_ timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    func stderrText() async -> String { await offPool { self.stderrBlocking() } }

    private func stderrBlocking() -> String { String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
}

struct MCPBridgeTests {
    @Test func handshakeAndRelay() async throws {
        let bridge = try #require(builtProduct("synod-editor-mcp"))
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let editor = MockEditor()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: editor), baseDirectory: base)
        let sock = try await listener.acquire()

        let p = RunningProcess(bridge, ["--socket", sock.path], env: ["SYNOD_EDITOR_TOKEN": token])
        try p.run()
        p.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        let r1 = try JSONParser.parse(try #require(await p.readLine()))
        #expect(r1["result"]?["serverInfo"]?["name"]?.stringValue == "synod-editor")
        p.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        p.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_buffer","arguments":{"path":"a.synod"}}}"#)
        let r2 = try JSONParser.parse(try #require(await p.readLine()))
        #expect(r2["id"]?.int64Value == 2)
        #expect(r2["result"]?["structuredContent"]?["text"]?.stringValue == "one\ntwo\n")
        // The token is never in argv.
        #expect(!p.process.arguments!.joined().contains(token))
        p.closeStdin()
        #expect(await p.waitForExit() == 0)
        await listener.release()
    }

    @Test func wrongTokenAndMissingSocketExitOneWithTheExactLine() async throws {
        let bridge = try #require(builtProduct("synod-editor-mcp"))
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: MockEditor()), baseDirectory: base)
        let sock = try await listener.acquire()
        let other = try MCPTokens.generate()
        let refused = RunningProcess(bridge, ["--socket", sock.path], env: ["SYNOD_EDITOR_TOKEN": other])
        try refused.run()
        #expect(await refused.waitForExit() == 1)
        #expect(await refused.stderrText() == BridgeHandshake.refusalMessage + "\n")
        #expect(BridgeHandshake.refusalMessage == "synod-editor-mcp: Synod is not accepting editor connections")
        await listener.release()

        let missing = RunningProcess(bridge, ["--socket", sock.path], env: ["SYNOD_EDITOR_TOKEN": token])
        try missing.run()
        #expect(await missing.waitForExit() == 1)
        #expect(await missing.stderrText() == "synod-editor-mcp: Synod is not accepting editor connections\n")
    }
}

struct FakeClaudeTests {
    func writeScript(_ dir: URL, _ json: String) throws -> URL {
        let u = dir.appendingPathComponent("script.json")
        try json.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func runsAScriptedSessionThroughTheBridge() async throws {
        let fake = try #require(builtProduct("fake-claude"))
        let bridge = try #require(builtProduct("synod-editor-mcp"))
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let editor = MockEditor()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: editor), baseDirectory: base)
        let sock = try await listener.acquire()
        let folder = try #require(await listener.folderURL)
        let config = try MCPConfigFile.write(servers: [MCPServerEntry(name: "synod-editor", command: bridge.path, args: ["--socket", sock.path], env: [("SYNOD_EDITOR_TOKEN", token)])], in: folder)
        let script = try writeScript(
            base,
            """
            {"sessionId":"sess-1","steps":[
              {"say":"Looking."},
              {"id":"r","tool":"read_buffer","arguments":{"path":"a.synod"}},
              {"tool":"apply_edits","arguments":{"path":"a.synod","version":"${r.version}","edits":[{"line":1,"col":1,"endLine":1,"endCol":1,"text":"x"}]}},
              {"tool":"replace_buffer","arguments":{"path":"a.synod","version":4,"text":"z"}},
              {"server":"synod","tool":"fmt","arguments":{}}
            ],"result":"All done."}
            """)
        let log = base.appendingPathComponent("log.json")
        let p = RunningProcess(
            fake,
            ["-p", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--mcp-config", config.url.path, "--strict-mcp-config", "--allowedTools", "Read,mcp__synod-editor__*", "--disallowedTools", "Write,Edit,mcp__synod__fmt", "--append-system-prompt", "hi", "--add-dir", "/x", "--resume", "old", "do it"],
            env: ["FAKE_CLAUDE_LOG": log.path, "FAKE_CLAUDE_SCRIPT": script.path])
        try p.run()
        var lines: [JSONValue] = []
        while let l = await p.readLine() { lines.append(try JSONParser.parse(l)) }
        #expect(await p.waitForExit() == 0)
        #expect(lines.first?["type"]?.stringValue == "system" && lines.first?["subtype"]?.stringValue == "init" && lines.first?["session_id"]?.stringValue == "sess-1")
        let toolUses = lines.compactMap { $0["message"]?["content"]?.arrayValue?.first }.filter { $0["type"]?.stringValue == "tool_use" }.compactMap { $0["name"]?.stringValue }
        #expect(toolUses == ["mcp__synod-editor__read_buffer", "mcp__synod-editor__apply_edits", "mcp__synod-editor__replace_buffer", "mcp__synod__fmt"])
        let last = try #require(lines.last)
        #expect(last["type"]?.stringValue == "result" && last["result"]?.stringValue == "All done.")
        #expect(await editor.calls.contains("apply_edits 1"))  // version came from the earlier result
        let results = lines.compactMap { $0["message"]?["content"]?.arrayValue?.first }.filter { $0["type"]?.stringValue == "tool_result" }
        #expect(results[1]["is_error"] == .bool(false))
        #expect(results[2]["is_error"] == .bool(true))  // read-only from the mock
        #expect(results[3]["content"]?.arrayValue?.first?["text"]?.stringValue == "permission denied: mcp__synod__fmt")

        let logged = try JSONParser.parse(try Data(contentsOf: log))
        #expect(logged["flags"]?["--resume"]?.stringValue == "old")
        #expect(logged["flags"]?["--mcp-config"]?.arrayValue?.first?.stringValue == config.url.path)
        #expect(logged["flags"]?["--strict-mcp-config"] == .bool(true))
        #expect(logged["configs"]?.arrayValue?.first?["mode"]?.stringValue == "600")
        #expect(logged["prompt"]?.stringValue == "do it")
        #expect(logged["env"]?["FAKE_CLAUDE_LOG"] != nil && logged["cwd"] != nil)
        #expect(logged["initialize"]?["synod-editor"]?["protocolVersion"]?.stringValue == "2025-11-25")
        config.remove()
        await listener.release()
    }

    @Test func rejectsUnknownOptions() async throws {
        let fake = try #require(builtProduct("fake-claude"))
        let p = RunningProcess(fake, ["--no-such-flag"])
        try p.run()
        #expect(await p.waitForExit() == 1)
        #expect(await p.stderrText().contains("unknown option"))
    }

    @Test func slowSessionStopsOnTerminate() async throws {
        let fake = try #require(builtProduct("fake-claude"))
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = try writeScript(base, #"{"steps":[{"say":"hi"}]}"#)
        let p = RunningProcess(fake, ["-p", "x"], env: ["FAKE_CLAUDE_SCRIPT": script.path, "FAKE_CLAUDE_SLOW": "30"])
        try p.run()
        let first = try #require(await p.readLine())
        #expect(first.contains("\"init\""))
        p.process.terminate()
        #expect(await p.waitForExit(timeout: 5) == 143)
    }
}

struct MCPConnectionCountTests {
    @Test func connectionsAreCountedPerToken() async throws {
        let base = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let token = try MCPTokens.generate()
        let other = try MCPTokens.generate()
        let listener = UnixSocketListener(authority: SingleGrantAuthority(token: token, editor: MockEditor()), baseDirectory: base)
        let sock = try await listener.acquire()
        defer { Task { await listener.release() } }
        let c = try #require(TestSocket(path: sock.path))
        c.send(BridgeHandshake(token: token, workspace: nil).line)
        #expect(await c.readLine() == #"{"ok":true}"#)
        #expect(await listener.connectionCount(token: token) == 1)
        #expect(await listener.connectionCount(token: other) == 0)
        await listener.closeConnections(token: token)
        #expect(await listener.connectionCount(token: token) == 0)
    }
}
