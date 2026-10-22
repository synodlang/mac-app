import AppKit
import Foundation
import SynodCore

/// A scripted MCP client: it starts the built `synod-editor-mcp` bridge like Claude Code would
/// (token in the environment, socket and workspace in argv) and speaks JSON-RPC lines to it.
@MainActor
final class BridgeClient {
    struct Reply {
        var isError = false
        var text = ""
        var structured: [String: Any]?
        var rpcError: String?
        var missing = false
    }

    private let proc = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var messages: [[String: Any]] = []
    private var consumer: Task<Void, Never>?
    private var errConsumer: Task<Void, Never>?
    private var nextID = 1
    private(set) var exitStatus: Int32?
    private(set) var stderrText = ""
    private var pending = Data()

    init(bridge: URL, socket: String, token: String, workspace: String?, cwd: URL) throws {
        proc.executableURL = bridge
        proc.arguments = ["--socket", socket] + (workspace.map { ["--workspace", $0] } ?? [])
        proc.environment = ["SYNOD_EDITOR_TOKEN": token, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        proc.currentDirectoryURL = cwd
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errors
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; cont.finish() } else { cont.yield(d) }
        }
        let (errStream, errCont) = AsyncStream.makeStream(of: Data.self)
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; errCont.finish() } else { errCont.yield(d) }
        }
        consumer = Task { [weak self] in for await d in stream { self?.ingest(d) } }
        errConsumer = Task { [weak self] in for await d in errStream { self?.stderrText += String(decoding: d, as: UTF8.self) } }
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.exitStatus = status }
        }
        try proc.run()
    }

    private func ingest(_ d: Data) {
        pending.append(d)
        while let nl = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { messages.append(obj) }
        }
    }

    var pid: Int32 { proc.processIdentifier }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        try? input.fileHandleForWriting.write(contentsOf: d + Data([10]))
    }

    func notify(_ method: String) { send(["jsonrpc": "2.0", "method": method]) }

    /// Sends a request and waits for its response (nil when the bridge ends or `timeout` passes).
    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 15) async -> [String: Any]? {
        let id = nextID
        nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while ContinuousClock.now < end {
            if let m = messages.first(where: { ($0["id"] as? Int) == id }) { return m }
            if exitStatus != nil, !messages.contains(where: { ($0["id"] as? Int) == id }) {
                try? await Task.sleep(for: .milliseconds(30))
                return messages.first(where: { ($0["id"] as? Int) == id })
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func initialize() async -> [String: Any]? {
        let r = await request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [String: Any](),
                                            "clientInfo": ["name": "mcp-check", "version": "0"]])
        if r != nil { notify("notifications/initialized") }
        return r
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:]) async -> Reply {
        guard let m = await request("tools/call", ["name": tool, "arguments": arguments]) else { return Reply(missing: true) }
        if let e = m["error"] as? [String: Any] {
            return Reply(isError: true, text: "", structured: nil, rpcError: "\(e["code"] ?? ""): \(e["message"] ?? "")")
        }
        let r = m["result"] as? [String: Any] ?? [:]
        let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return Reply(isError: (r["isError"] as? Bool) ?? false, text: text, structured: r["structuredContent"] as? [String: Any])
    }

    /// Waits for the process to end; nil on timeout.
    func waitExit(timeout: Double = 5) async -> Int32? {
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while ContinuousClock.now < end {
            if let s = exitStatus { return s }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return exitStatus
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if proc.isRunning { proc.terminate() }
        consumer?.cancel()
        errConsumer?.cancel()
    }
}

/// Collects the editor server's log entries (they carry no buffer text by construction).
nonisolated final class MCPLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(MCPCallLogEntry, String)] = []
    func add(_ e: MCPCallLogEntry, _ kind: String) { lock.lock(); items.append((e, kind)); lock.unlock() }
    var entries: [(MCPCallLogEntry, String)] { lock.lock(); defer { lock.unlock() }; return items }
}

/// `--mcp-check <module> [--bridge b] [--golden tools.json] [--report f]` (addendum A10 item 14): the
/// editor MCP server through the built bridge on a temporary copy of the examples, with a locked screen.
enum HeadlessMCP {
    typealias Check = HeadlessEditor.Check
    static let file = "gossip/gossip.synod"

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--mcp-check", in: args).first else {
            h.fail("usage: --mcp-check <module> [--bridge synod-editor-mcp] [--golden tools.json] [--report file]")
            return 2
        }
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let bridge = h.value(of: "--bridge", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? HelperTools.editorBridge()
        guard let bridge, FileManager.default.isExecutableFile(atPath: bridge.path) else {
            h.fail("synod-editor-mcp was not found; build it (swift build) or pass --bridge")
            return 2
        }
        let rig: HeadlessLearning.Rig
        do { rig = try HeadlessLearning.Rig(module: modulePath) } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("synod-mcp-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            rig.close()
            try? FileManager.default.removeItem(at: scratch)
        }
        var read: WorkspaceModel?
        if let ex = AppEnvironment.shared.examplesURL, let ws = try? Workspace.open(ex) {
            read = WorkspaceModel(workspace: ws, recordRecent: false)
            read?.editor.undoGroupsByEvent = false
        }
        defer { read?.stop() }
        let ctx = Context(rig: rig, readOnly: read, bridge: bridge, synod: tools.synod, runner: SynodRunner(executable: tools.synod),
                          scratch: scratch, golden: goldenData(args))
        let checks = await ctx.runAll()
        return HeadlessChecks.finish(name: "mcp-check", checks: checks, module: rig.root.lastPathComponent, args: args)
    }

    /// The golden `tools/list` result: `--golden`, else the repository's fixture, else nil.
    static func goldenData(_ args: [String], file: String = #filePath) -> Data? {
        if let p = HeadlessCommands.value(of: "--golden", in: args) { return try? Data(contentsOf: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try? Data(contentsOf: url.appendingPathComponent("Tests/SynodCoreTests/Fixtures/mcp/tools.json"))
    }

    static func mode(_ path: String) -> Int? {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_mode & 0o777) : nil
    }

    /// TCP listeners of this process (`lsof -iTCP -sTCP:LISTEN`).
    static func tcpListeners() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        return max(0, lines.count - 1)
    }

    @MainActor
    final class Context {
        let rig: HeadlessLearning.Rig
        let readOnly: WorkspaceModel?
        let bridge: URL
        let synod: URL
        let runner: SynodRunner
        let scratch: URL
        let golden: Data?
        let hub = EditorMCPHub()
        let log = MCPLogBox()
        var model: WorkspaceModel { rig.model }
        var root: URL { rig.root }

        init(rig: HeadlessLearning.Rig, readOnly: WorkspaceModel?, bridge: URL, synod: URL, runner: SynodRunner, scratch: URL, golden: Data?) {
            self.rig = rig
            self.readOnly = readOnly
            self.bridge = bridge
            self.synod = synod
            self.runner = runner
            self.scratch = scratch
            self.golden = golden
            hub.logSink = { [log] e, k in log.add(e, k) }
            hub.windows = { [weak rig] in [rig?.model].compactMap { $0 } }
        }

        func ok(_ c: inout Check) { c.ok = c.failures.isEmpty }
        func fail(_ c: inout Check, _ m: String) { if c.failures.count < 8 { c.failures.append(m) } }

        func disk(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

        /// What `synod fmt` makes of `text` as `path` of a throwaway module.
        func formatted(_ text: String, as path: String) async -> String? {
            let dir = scratch.appendingPathComponent("fmt-\(UUID().uuidString)")
            let url = dir.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "module example.com/fmt\nsynod 0.2\n".write(to: dir.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
                try text.write(to: url, atomically: true, encoding: .utf8)
                _ = try await runner.exec(["fmt", path], cwd: dir)
                return try String(contentsOf: url, encoding: .utf8)
            } catch { return nil }
        }

        func start(workspace: String?, token: String, socket: String) -> BridgeClient? {
            try? BridgeClient(bridge: bridge, socket: socket, token: token, workspace: workspace, cwd: root)
        }

        func runAll() async -> [Check] {
            var tools = Check(name: "tools/list equals the golden")
            var buffers = Check(name: "unsaved text, edits and undo")
            var errorsCheck = Check(name: "version, range, path and read-only errors")
            var saving = Check(name: "save_files and create_file")
            var tokens = Check(name: "wrong token refused")
            var life = Check(name: "no TCP listener, socket modes, clean removal")
            var external = Check(name: "external access on, off and Disconnect")
            var logging = Check(name: "log entries carry no text")

            try? await model.stage?.waitUntilReady()
            if let program = model.workspace.scan().programs.first(where: { $0.relPath == "gossip" }) ?? model.workspace.scan().programs.first {
                try? await rig.select(program)
            }
            let editor = model.editor
            let originalDisk = disk(file) ?? ""
            guard let session = try? await hub.beginRequest(for: model, synod: synod, bridge: bridge) else {
                fail(&tools, "the listener did not start")
                return [tools]
            }
            guard let a = start(workspace: nil, token: session.token, socket: session.socket.path) else {
                fail(&tools, "the bridge did not start")
                await hub.endRequest(session)
                return [tools]
            }
            defer { a.close() }

            // Lifetime while the session runs.
            let tcp = HeadlessMCP.tcpListeners()
            life.metrics["tcpListeners"] = Double(tcp)
            if tcp != 0 { fail(&life, "\(tcp) TCP listeners") }
            let folder = session.socket.deletingLastPathComponent().path
            if HeadlessMCP.mode(session.socket.path) != 0o600 { fail(&life, "socket mode is \(HeadlessMCP.mode(session.socket.path).map { String($0, radix: 8) } ?? "missing")") }
            if HeadlessMCP.mode(folder) != 0o700 { fail(&life, "folder mode is \(HeadlessMCP.mode(folder).map { String($0, radix: 8) } ?? "missing")") }
            if HeadlessMCP.mode(session.config.url.path) != 0o600 { fail(&life, "config mode is \(HeadlessMCP.mode(session.config.url.path).map { String($0, radix: 8) } ?? "missing")") }
            if session.socket.path.utf8.count >= 104 { fail(&life, "socket path is too long") }

            guard let initialized = await a.initialize(), let result = initialized["result"] as? [String: Any] else {
                fail(&tools, "no initialize result: \(a.stderrText)")
                await hub.endRequest(session)
                return [tools, life]
            }
            if ((result["serverInfo"] as? [String: Any])?["name"] as? String) != "synod-editor" { fail(&tools, "server name is \(String(describing: result["serverInfo"]))") }
            let listed = (await a.request("tools/list"))?["result"] as? [String: Any]
            if let golden, let want = (try? JSONSerialization.jsonObject(with: golden)) as? [String: Any] {
                if (listed as NSDictionary?)?.isEqual(want) != true { fail(&tools, "tools/list differs from the golden") }
            } else {
                // No golden file next to the binary: compare with the schemas the server is built from.
                let names = (listed?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                if names != hub.registry(model: model, kind: .promptBar).tools.map(\.name) { fail(&tools, "tool names are \(names)") }
                tools.metrics["goldenFile"] = 0
            }
            tools.metrics["tools"] = Double((listed?["tools"] as? [Any])?.count ?? 0)
            ok(&tools)

            // Unsaved text.
            guard let doc = try? editor.open(file: file) else {
                fail(&buffers, "cannot open \(file)")
                await hub.endRequest(session)
                return [tools, buffers]
            }
            let userNote = "# user note\n"
            doc.perform(actionName: "Typing") { doc.replace(NSRange(location: doc.positions.utf16Offset(line: 2, col: 1) ?? 0, length: 0), with: userNote) }
            let read1 = await a.call("read_buffer", ["path": file])
            let text1 = read1.structured?["text"] as? String ?? ""
            let version1 = read1.structured?["version"] as? Int ?? -1
            if read1.isError || text1 != doc.text { fail(&buffers, "read_buffer did not return the unsaved text: \(read1.text.prefix(80))") }
            if read1.structured?["dirty"] as? Bool != true { fail(&buffers, "read_buffer says the buffer is clean") }
            if disk(file) != originalDisk { fail(&buffers, "the disk changed") }
            let ranged = await a.call("read_buffer", ["path": file, "startLine": 2, "endLine": 3])
            if (ranged.structured?["text"] as? String) != Array(doc.text.components(separatedBy: "\n").prefix(3).dropFirst()).map({ $0 + "\n" }).joined() {
                fail(&buffers, "a line range returned \(ranged.structured?["text"] ?? "nothing")")
            }
            let listedFiles = (await a.call("list_files")).structured?["files"] as? [[String: Any]] ?? []
            if let entry = listedFiles.first(where: { $0["path"] as? String == file }) {
                if entry["dirty"] as? Bool != true || entry["open"] as? Bool != true { fail(&buffers, "list_files does not show the dirty buffer") }
            } else { fail(&buffers, "list_files lacks \(file)") }

            // apply_edits: misspell net.Send as net.Sned.
            var edit: [String: Any]?
            for (i, line) in text1.components(separatedBy: "\n").enumerated() {
                if let r = line.range(of: "net.Send") {
                    let col = line.unicodeScalars.distance(from: line.unicodeScalars.startIndex, to: r.lowerBound.samePosition(in: line.unicodeScalars)!) + 1
                    edit = ["line": i + 1, "col": col + 4, "endLine": i + 1, "endCol": col + 8, "text": "Sned"]
                    break
                }
            }
            let textBeforeEdit = doc.text
            if let edit {
                let t0 = ContinuousClock.now
                let applied = await a.call("apply_edits", ["path": file, "version": version1, "edits": [edit]])
                if applied.isError { fail(&buffers, "apply_edits: \(applied.text)") }
                let newVersion = applied.structured?["version"] as? Int ?? -1
                if newVersion <= version1 { fail(&buffers, "the version did not grow") }
                if !doc.text.contains("net.Sned") { fail(&buffers, "the buffer has no net.Sned") }
                let diags = await a.call("get_diagnostics", ["fresh": true])
                let d = ContinuousClock.now - t0
                let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                buffers.metrics["diagnosticsMs"] = ms.rounded()
                let codes = (diags.structured?["diagnostics"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
                if !codes.contains("unknown-phrase") { fail(&buffers, "fresh diagnostics lack unknown-phrase: \(codes)") }
                if diags.structured?["stale"] as? Bool != false { fail(&buffers, "the diagnostics are stale") }
                if ms > 2000 { fail(&buffers, "diagnostics took \(Int(ms)) ms") }
                if disk(file) != originalDisk { fail(&buffers, "the disk changed with the edit") }
                // A stale version, a bad range and an overlap.
                let stale = await a.call("apply_edits", ["path": file, "version": version1, "edits": [edit]])
                if !stale.isError || !stale.text.hasPrefix("version-mismatch") { fail(&errorsCheck, "a stale version gave \(stale.text.prefix(60))") }
                let bad = await a.call("apply_edits", ["path": file, "version": newVersion, "edits": [["line": 9999, "col": 1, "endLine": 9999, "endCol": 1, "text": "x"]]])
                if !bad.isError || !bad.text.hasPrefix("bad-range") { fail(&errorsCheck, "a bad range gave \(bad.text.prefix(60))") }
                let overlap = await a.call("apply_edits", ["path": file, "version": newVersion, "edits": [edit, edit]])
                if !overlap.isError || !overlap.text.hasPrefix("bad-range") { fail(&errorsCheck, "overlapping edits gave \(overlap.text.prefix(60))") }
                // One undo restores the bytes.
                if doc.undoManager.undoActionName != "Claude Edit" { fail(&buffers, "undo is named \(doc.undoManager.undoActionName)") }
                doc.undoManager.undo()
                if doc.text != textBeforeEdit { fail(&buffers, "one undo did not restore the text") }
            } else {
                fail(&buffers, "no net.Send in \(file)")
            }
            ok(&buffers)

            // Paths and read-only.
            for bad in ["../x", "/etc/passwd", "a/../../x"] {
                let r = await a.call("read_buffer", ["path": bad])
                if !r.isError || !r.text.hasPrefix("outside-module") { fail(&errorsCheck, "\(bad) gave \(r.text.prefix(60))") }
            }
            let missing = await a.call("read_buffer", ["path": "nothing/here.synod"])
            if !missing.isError || !missing.text.hasPrefix("not-found") { fail(&errorsCheck, "a missing file gave \(missing.text.prefix(60))") }
            let vendorWrite = await a.call("create_file", ["path": "vendor/x/x.synod", "text": "# package x\n"])
            if !vendorWrite.isError || !vendorWrite.text.hasPrefix("read-only") { fail(&errorsCheck, "a write to vendor/ gave \(vendorWrite.text.prefix(60))") }
            if let readOnly {
                let g = try? await hub.beginRequest(for: readOnly, synod: synod, bridge: bridge)
                if let g, let b = start(workspace: nil, token: g.token, socket: g.socket.path) {
                    _ = await b.initialize()
                    let r = await b.call("read_buffer", ["path": file])
                    if r.isError { fail(&errorsCheck, "reading the bundled examples failed: \(r.text.prefix(60))") }
                    for (tool, a) in [("apply_edits", ["path": file, "version": 0, "edits": [["line": 1, "col": 1, "endLine": 1, "endCol": 1, "text": "x"]]] as [String: Any]),
                                      ("replace_buffer", ["path": file, "version": 0, "text": "x"]),
                                      ("create_file", ["path": "new/new.synod", "text": "x"]),
                                      ("save_files", ["paths": [file]])] {
                        let w = await b.call(tool, a)
                        if !w.isError || !w.text.hasPrefix("read-only") { fail(&errorsCheck, "\(tool) on the examples gave \(w.text.prefix(60))") }
                    }
                    b.close()
                } else { fail(&errorsCheck, "no session on the bundled examples") }
                if let g { await hub.endRequest(g) }
            } else { fail(&errorsCheck, "the bundled examples are not available") }
            ok(&errorsCheck)

            // save_files: formatted, atomic, then a run.
            let generation = model.coordinator.generation
            let bufferBeforeSave = doc.text
            let saved = await a.call("save_files", ["paths": [file]])
            if saved.isError || (saved.structured?["failed"] as? [Any])?.isEmpty != true { fail(&saving, "save_files: \(saved.text.prefix(100))") }
            let expected = await formatted(bufferBeforeSave, as: file)
            if expected == nil || disk(file) != expected { fail(&saving, "the saved file is not the synod fmt output") }
            if doc.isDirty { fail(&saving, "the buffer is still dirty") }
            let ran = await HeadlessLearning.wait(2) { model.coordinator.generation > generation }
            if !ran { fail(&saving, "no run started within 2 s") }

            // create_file.
            let messy = "# package main\nuse std/sim\ndefine main\n  sim.Seed    1\n  sim.StopAt   1s\n\n\n"
            let c1 = await a.call("create_file", ["path": "extra/demo2.synod", "text": messy])
            if c1.isError { fail(&saving, "create_file: \(c1.text.prefix(100))") }
            let want2 = await formatted(messy, as: "extra/demo2.synod")
            if want2 == nil || disk("extra/demo2.synod") != want2 { fail(&saving, "extra/demo2.synod is not formatted") }
            if c1.structured?["formatted"] as? Bool != true { fail(&saving, "create_file did not report formatting") }
            let c2 = await a.call("create_file", ["path": "extra/demo2.synod", "text": messy])
            if !c2.isError || !c2.text.hasPrefix("exists") { fail(&saving, "a second create_file gave \(c2.text.prefix(60))") }
            let selection = await a.call("get_selection")
            if selection.isError { fail(&saving, "get_selection: \(selection.text.prefix(60))") }
            let opened = await a.call("open_file", ["path": file, "line": 3])
            if opened.isError || editor.current?.file != file { fail(&saving, "open_file did not show \(file)") }
            ok(&saving)

            // A wrong token is refused while the listener runs.
            let wrong = start(workspace: nil, token: (try? MCPTokens.generate()) ?? String(repeating: "a", count: 64), socket: session.socket.path)
            let wrongStatus = await wrong?.waitExit(timeout: 5)
            if wrongStatus != 1 { fail(&tokens, "the bridge exited with \(wrongStatus.map(String.init) ?? "no status")") }
            if !(wrong?.stderrText.contains("not accepting editor connections") ?? false) { fail(&tokens, "refusal message was \(wrong?.stderrText ?? "")") }
            wrong?.close()
            ok(&tokens)

            // The session ends: socket, folder and config go.
            a.close()
            await hub.endRequest(session)
            let socketGone = !FileManager.default.fileExists(atPath: session.socket.path) && !FileManager.default.fileExists(atPath: folder)
            let configGone = !FileManager.default.fileExists(atPath: session.config.url.path)
            life.metrics["socketRemoved"] = socketGone ? 1 : 0
            life.metrics["configRemoved"] = configGone ? 1 : 0
            if !socketGone { fail(&life, "the socket or its folder is still there") }
            if !configGone { fail(&life, "the config file is still there") }
            if await hub.listener.isListening { fail(&life, "the listener is still up") }
            if await hub.table.count != 0 { fail(&life, "a token is still valid") }
            let after = HeadlessMCP.tcpListeners()
            if after != 0 { fail(&life, "\(after) TCP listeners after the session") }
            ok(&life)

            // External access.
            let stale = start(workspace: root.path, token: session.token, socket: session.socket.path)
            if await stale?.waitExit(timeout: 5) != 1 { fail(&external, "a bridge connected with external access off") }
            stale?.close()
            await hub.setExternal(true)
            let externalTokenUsed = hub.externalToken
            if let token = hub.externalToken, let socket = hub.externalSocket {
                if HeadlessMCP.mode(socket.path) != 0o600 { fail(&external, "external socket mode is \(HeadlessMCP.mode(socket.path).map { String($0, radix: 8) } ?? "missing")") }
                let noWorkspace = start(workspace: nil, token: token, socket: socket.path)
                if await noWorkspace?.waitExit(timeout: 5) != 1 { fail(&external, "a bridge without --workspace connected") }
                noWorkspace?.close()
                let other = start(workspace: scratch.path, token: token, socket: socket.path)
                if await other?.waitExit(timeout: 5) != 1 { fail(&external, "a bridge for another folder connected") }
                other?.close()
                if let e = start(workspace: root.path, token: token, socket: socket.path) {
                    let initialized = await e.initialize()
                    if initialized?["result"] == nil { fail(&external, "no initialize through --workspace: \(e.stderrText)") }
                    let files = (await e.call("list_files")).structured?["files"] as? [[String: Any]] ?? []
                    if !files.contains(where: { $0["path"] as? String == file }) { fail(&external, "list_files lacks \(file)") }
                    let shown = await HeadlessLearning.wait(3) { hub.externalConnected(to: model) }
                    if !shown { fail(&external, "the window does not show the connection") }
                    // Disconnect closes the connection and rotates the token.
                    await hub.disconnectExternal()
                    if await e.waitExit(timeout: 5) == nil { fail(&external, "the connection stayed open after Disconnect") }
                    e.close()
                    if hub.externalConnected(to: model) { fail(&external, "the window still shows the connection") }
                    let old = start(workspace: root.path, token: token, socket: socket.path)
                    if await old?.waitExit(timeout: 5) != 1 { fail(&external, "the old token still works") }
                    old?.close()
                    if let fresh = hub.externalToken, fresh != token, let again = start(workspace: root.path, token: fresh, socket: socket.path) {
                        if (await again.initialize())?["result"] == nil { fail(&external, "the new token does not work") }
                        again.close()
                    } else { fail(&external, "the token did not rotate") }
                } else { fail(&external, "the external bridge did not start") }
                await hub.setExternal(false)
                let gone = !FileManager.default.fileExists(atPath: socket.path)
                if !gone { fail(&external, "the socket stayed after turning external access off") }
                let late = start(workspace: root.path, token: token, socket: socket.path)
                if await late?.waitExit(timeout: 5) != 1 { fail(&external, "a bridge connected after external access went off") }
                late?.close()
            } else {
                fail(&external, "no external token\(hub.lastError.map { ": \($0)" } ?? "")")
            }
            if hub.externalEnabled { fail(&external, "external access is still on") }
            if UserDefaults.standard.object(forKey: "externalEditorAccess") != nil { fail(&external, "external access was stored") }
            ok(&external)

            // The log has tool, path and sizes only.
            let entries = log.entries
            logging.metrics["entries"] = Double(entries.count)
            if entries.isEmpty { fail(&logging, "no log entries") }
            let dump = entries.map { "\($0.0)" }.joined(separator: "\n")
            for secret in ["user note", "Sned", session.token, externalTokenUsed].compactMap({ $0 }) where dump.contains(secret) { fail(&logging, "a log entry holds \(secret)") }
            if !entries.contains(where: { $0.1 == "prompt-bar" }) { fail(&logging, "no prompt-bar entry") }
            if !entries.contains(where: { $0.1 == "external" }) { fail(&logging, "no external entry") }
            ok(&logging)
            return [tools, buffers, errorsCheck, saving, tokens, life, external, logging]
        }
    }
}
