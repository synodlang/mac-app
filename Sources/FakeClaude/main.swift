import Foundation

// fake-claude: a test stand-in for the `claude` CLI (not bundled).
//
// It parses argv like Claude Code, starts every MCP server of --mcp-config like Claude Code does (command, args,
// env merged over its own environment, stdio JSON-RPC lines), plays a scripted session and prints stream-json.
//
// Environment:
//   FAKE_CLAUDE_LOG     file that receives a JSON log (argv, cwd, env, parsed flags, config, MCP traffic)
//   FAKE_CLAUDE_SCRIPT  JSON script file (see below); without it only initialize and tools/list run
//   FAKE_CLAUDE_SLOW    seconds to sleep before every step (a bare "1" or any non-number means 60), for Stop tests
//
// Script: {"sessionId":"s1","steps":[
//   {"say":"text"}                                   assistant text line
//   {"sleep":200}                                    milliseconds
//   {"id":"a","server":"synod-editor","tool":"read_buffer","arguments":{"path":"x.synod","version":"${a.version}"}}
//  ],"result":"done","isError":false,"exitCode":0}
// "${<stepId>.<dotted.path>}" as a whole string argument is replaced by that value of an earlier step's
// structuredContent (or of the parsed text). server defaults to "synod-editor".
// A call is denied (is_error tool_result "permission denied") when --allowedTools is given and does not match
// the name mcp__<server>__<tool>, or --disallowedTools matches it. Patterns are exact or end in "*".

final class Children: @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [Process] = []
    private var sources: [DispatchSourceSignal] = []
    func keep(_ s: DispatchSourceSignal) { lock.lock(); sources.append(s); lock.unlock() }
    func add(_ p: Process) { lock.lock(); procs.append(p); lock.unlock() }
    func killAll() {
        lock.lock()
        let all = procs
        lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

struct Stdout {
    static let lock = NSLock()
    static func line(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock()
        FileHandle.standardOutput.write(d + Data([10]))
        lock.unlock()
    }
}

func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data() }
func parse(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

/// A blocking line client over a child's pipes.
final class MCPClient {
    let proc = Process()
    let toChild = Pipe()
    let fromChild = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init(command: String, args: [String], env: [String: String], cwd: String) {
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = toChild
        proc.standardOutput = fromChild
        proc.standardError = FileHandle.nullDevice
    }

    func start() throws { try proc.run() }

    func send(_ obj: [String: Any]) {
        try? toChild.fileHandleForWriting.write(contentsOf: json(obj) + Data([10]))
    }

    func readLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fromChild.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Sends a request and waits for its response; returns the parsed message.
    func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while let line = readLine() {
            if let m = parse(line) as? [String: Any], (m["id"] as? Int) == id { return m }
        }
        return nil
    }

    func notify(_ method: String) { send(["jsonrpc": "2.0", "method": method]) }

    func close() {
        try? toChild.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning { proc.terminate() }
    }
}

enum FakeClaude {
    static let valueFlags: Set<String> = [
        "--output-format", "--input-format", "--model", "--resume", "-r", "--append-system-prompt", "--system-prompt", "--permission-mode",
        "--max-turns", "--session-id", "--fallback-model", "--settings", "--setting-sources", "--agent", "--agents", "--plugin-dir",
        "--permission-prompt-tool", "--max-thinking-tokens", "--name", "-n",
    ]
    /// Flags that take one or more values, like Claude Code's variadic options.
    static let listFlags: Set<String> = [
        "--mcp-config", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--add-dir", "--tools",
    ]
    static let boolFlags: Set<String> = [
        "-p", "--print", "--verbose", "--strict-mcp-config", "--include-partial-messages", "--dangerously-skip-permissions", "-c", "--continue",
        "--debug", "-d", "--fork-session", "--ide", "--replay-user-messages", "-h", "--help", "-v", "--version", "--bare",
    ]

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        pattern.hasSuffix("*") ? name.hasPrefix(String(pattern.dropLast())) : pattern == name
    }

    static func splitTools(_ values: [String]) -> [String] {
        values.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
    }

    static func lookup(_ value: Any?, path: String) -> Any? {
        var cur = value
        for part in path.split(separator: ".") {
            if let d = cur as? [String: Any] { cur = d[String(part)] } else if let a = cur as? [Any], let i = Int(part), i < a.count { cur = a[i] } else { return nil }
        }
        return cur
    }

    static func substitute(_ v: Any, results: [String: Any]) -> Any {
        if let s = v as? String, s.hasPrefix("${"), s.hasSuffix("}") {
            let ref = String(s.dropFirst(2).dropLast())
            if let dot = ref.firstIndex(of: "."), let base = results[String(ref[..<dot])],
                let found = lookup(base, path: String(ref[ref.index(after: dot)...]))
            {
                return found
            }
            return s
        }
        if let d = v as? [String: Any] { return d.mapValues { substitute($0, results: results) } }
        if let a = v as? [Any] { return a.map { substitute($0, results: results) } }
        return v
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath

        var flags: [String: Any] = [:]
        var positional: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1
            if a == "--" {
                positional += argv[i...]
                break
            }
            if a.hasPrefix("-") && a.count > 1 {
                var name = a
                var inline: String?
                if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                    name = String(a[..<eq])
                    inline = String(a[a.index(after: eq)...])
                }
                if boolFlags.contains(name) {
                    flags[name] = true
                } else if valueFlags.contains(name) {
                    guard let v = inline ?? (i < argv.count ? argv[i] : nil) else { fail("error: option '\(name) <value>' argument missing") }
                    if inline == nil { i += 1 }
                    flags[name] = v
                } else if listFlags.contains(name) {
                    var values: [String] = inline.map { [$0] } ?? []
                    if inline == nil {
                        while i < argv.count, !argv[i].hasPrefix("-") {
                            values.append(argv[i])
                            i += 1
                        }
                    }
                    if values.isEmpty { fail("error: option '\(name) <values...>' argument missing") }
                    flags[name] = ((flags[name] as? [String]) ?? []) + values
                } else {
                    fail("error: unknown option '\(a)'")
                }
            } else {
                positional.append(a)
            }
        }

        var prompt = positional.joined(separator: " ")
        if prompt.isEmpty, isatty(0) == 0 {
            prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }

        let allowed = splitTools(flags["--allowedTools"] as? [String] ?? flags["--allowed-tools"] as? [String] ?? [])
        let disallowed = splitTools(flags["--disallowedTools"] as? [String] ?? flags["--disallowed-tools"] as? [String] ?? [])

        var log: [String: Any] = [
            "argv": argv, "cwd": cwd, "env": env, "flags": flags, "prompt": prompt, "allowedTools": allowed, "disallowedTools": disallowed,
            "pid": Int(getpid()),
        ]
        let logPath = env["FAKE_CLAUDE_LOG"]
        func writeLog() {
            guard let logPath else { return }
            try? json(log).write(to: URL(fileURLWithPath: logPath))
        }
        writeLog()

        let children = Children()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for (sig, code) in [(SIGTERM, Int32(143)), (SIGINT, Int32(130))] {
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler {
                children.killAll()
                log["interrupted"] = true
                exit(code)
            }
            s.resume()
            children.keep(s)
        }

        let script = env["FAKE_CLAUDE_SCRIPT"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap(parse) as? [String: Any] ?? [:]
        let sessionID = (script["sessionId"] as? String) ?? (flags["--resume"] as? String) ?? (flags["-r"] as? String) ?? "fake-session-\(UUID().uuidString.prefix(8).lowercased())"
        let slow: Double? = env["FAKE_CLAUDE_SLOW"].map { Double($0).map { $0 > 1 ? $0 : 60 } ?? 60 }

        // Config files and inline JSON, merged like Claude Code (later files win).
        var servers: [(name: String, command: String, args: [String], env: [String: String])] = []
        var configInfo: [[String: Any]] = []
        for spec in flags["--mcp-config"] as? [String] ?? [] {
            var data: Data?
            var info: [String: Any] = ["spec": spec]
            if spec.hasPrefix("{") {
                data = Data(spec.utf8)
            } else {
                data = try? Data(contentsOf: URL(fileURLWithPath: spec))
                if let attrs = try? FileManager.default.attributesOfItem(atPath: spec), let perm = attrs[.posixPermissions] as? Int {
                    info["mode"] = String(perm, radix: 8)
                }
            }
            guard let data, let cfg = parse(data) as? [String: Any], let map = cfg["mcpServers"] as? [String: Any] else {
                fail("Error: Invalid MCP configuration: \(spec)")
            }
            info["config"] = cfg
            configInfo.append(info)
            for (name, raw) in map.sorted(by: { $0.key < $1.key }) {
                guard let e = raw as? [String: Any], let command = e["command"] as? String else { fail("Error: Invalid MCP configuration: server \(name) has no command") }
                if let t = e["type"] as? String, t != "stdio" { fail("Error: Invalid MCP configuration: unsupported type \(t)") }
                servers.removeAll { $0.name == name }
                servers.append((name, command, e["args"] as? [String] ?? [], e["env"] as? [String: String] ?? [:]))
            }
        }
        log["configs"] = configInfo

        var clients: [String: MCPClient] = [:]
        var statuses: [[String: Any]] = []
        var toolNames: [String] = []
        var negotiated: [String: Any] = [:]
        var listed: [String: Any] = [:]
        for s in servers {
            let c = MCPClient(command: s.command, args: s.args, env: s.env, cwd: cwd)
            var status = "failed"
            do {
                try c.start()
                children.add(c.proc)
                let initResp = c.request(
                    "initialize",
                    ["protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "fake-claude", "version": "0.0.0"]])
                if let result = initResp?["result"] as? [String: Any] {
                    negotiated[s.name] = result
                    c.notify("notifications/initialized")
                    if let tl = c.request("tools/list", [:])?["result"] as? [String: Any], let tools = tl["tools"] as? [[String: Any]] {
                        listed[s.name] = tools.compactMap { $0["name"] as? String }
                        toolNames += tools.compactMap { ($0["name"] as? String).map { "mcp__\(s.name)__\($0)" } }
                        status = "connected"
                        clients[s.name] = c
                    }
                }
            } catch {}
            if status != "connected" { c.close() }
            statuses.append(["name": s.name, "status": status])
        }
        log["mcpServers"] = statuses
        log["initialize"] = negotiated
        log["toolsListed"] = listed
        writeLog()

        let start = Date()
        Stdout.line([
            "type": "system", "subtype": "init", "session_id": sessionID, "cwd": cwd, "model": (flags["--model"] as? String) ?? "fake-model",
            "tools": toolNames, "mcp_servers": statuses, "permissionMode": (flags["--permission-mode"] as? String) ?? "default",
        ])

        var results: [String: Any] = [:]
        var calls: [[String: Any]] = []
        var turns = 0
        for step in script["steps"] as? [[String: Any]] ?? [] {
            if let slow { Thread.sleep(forTimeInterval: slow) }
            if let ms = step["sleep"] as? Double { Thread.sleep(forTimeInterval: ms / 1000) }
            if let say = step["say"] as? String {
                turns += 1
                Stdout.line([
                    "type": "assistant", "session_id": sessionID,
                    "message": ["id": "msg_\(turns)", "type": "message", "role": "assistant", "content": [["type": "text", "text": say]]],
                ])
                continue
            }
            guard let tool = step["tool"] as? String else { continue }
            let server = (step["server"] as? String) ?? "synod-editor"
            let args = substitute(step["arguments"] ?? [String: Any](), results: results)
            let fullName = "mcp__\(server)__\(tool)"
            turns += 1
            let useID = "toolu_\(turns)"
            Stdout.line([
                "type": "assistant", "session_id": sessionID,
                "message": [
                    "id": "msg_\(turns)", "type": "message", "role": "assistant",
                    "content": [["type": "tool_use", "id": useID, "name": fullName, "input": args]],
                ],
            ])
            var text = ""
            var isError = false
            var structured: Any?
            let denied = (!allowed.isEmpty && !allowed.contains { globMatch($0, fullName) }) || disallowed.contains { globMatch($0, fullName) }
            if denied {
                text = "permission denied: \(fullName)"
                isError = true
            } else if let c = clients[server] {
                if let resp = c.request("tools/call", ["name": tool, "arguments": args]) {
                    if let err = resp["error"] as? [String: Any] {
                        text = "error \(err["code"] ?? ""): \(err["message"] ?? "")"
                        isError = true
                    } else if let r = resp["result"] as? [String: Any] {
                        isError = (r["isError"] as? Bool) ?? false
                        structured = r["structuredContent"]
                        text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                    }
                } else {
                    text = "MCP server \(server) closed the connection"
                    isError = true
                }
            } else {
                text = "No such tool available: \(fullName)"
                isError = true
            }
            if let id = step["id"] as? String { results[id] = structured ?? parse(Data(text.utf8)) ?? text }
            calls.append(["tool": fullName, "arguments": args, "isError": isError, "text": text, "denied": denied])
            Stdout.line([
                "type": "user", "session_id": sessionID,
                "message": [
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": useID, "content": [["type": "text", "text": text]], "is_error": isError]],
                ],
            ])
        }
        log["calls"] = calls
        writeLog()

        for (_, c) in clients { c.close() }
        let isError = (script["isError"] as? Bool) ?? false
        Stdout.line([
            "type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": isError,
            "result": (script["result"] as? String) ?? "done", "session_id": sessionID, "num_turns": turns,
            "duration_ms": Int(Date().timeIntervalSince(start) * 1000), "total_cost_usd": 0,
        ])
        exit(Int32((script["exitCode"] as? Int) ?? (isError ? 1 : 0)))
    }
}

FakeClaude.main()
