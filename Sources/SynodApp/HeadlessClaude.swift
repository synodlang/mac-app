import AppKit
import Foundation
import SynodCore

/// `--claude-check <module> [--claude <fake-claude>] [--skills <agent-skills>] [--report f]`: the prompt
/// bar against the built `fake-claude` on a temporary copy (plan check 10 and addendum A10 item 15).
/// The fake starts the real bridge and `synod mcp` from the request's config file and plays a scripted
/// session, so the whole chain runs: save gate, argv, environment, config file lifetime, MCP edits as
/// "Claude Edit" undo groups, progress lines, the new program, the banner, Revert, `--resume`, Stop.
enum HeadlessClaude {
    typealias Check = HeadlessEditor.Check

    static let demo = "twopc/demo.synod"
    static let created = "claudedemo/claudedemo.synod"
    static let createdText = "# package main\nuse std/sim\n\ndefine main\n  sim.Seed 1\n  sim.StopAt 1s\n"

    /// The allowlisted environment keys plus what the wrapper script and its shell add.
    static let allowedEnvironment: Set<String> = Set(ClaudeInvocation.inheritedVariables)
        .union(["PATH", "NO_COLOR", "TERM", "FAKE_CLAUDE_LOG", "FAKE_CLAUDE_SCRIPT", "FAKE_CLAUDE_SLOW", "PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"])

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--claude-check", in: args).first else {
            h.fail("usage: --claude-check <module> [--claude <fake-claude>] [--skills <agent-skills>] [--report file]")
            return 2
        }
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let fakeURL = h.value(of: "--claude", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? HelperTools.helper("fake-claude")
        guard let fake = fakeURL, FileManager.default.isExecutableFile(atPath: fake.path) else {
            h.fail("fake-claude was not found; build it (swift build) or pass --claude")
            return 2
        }
        let skills = h.value(of: "--skills", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? HelperTools.agentSkills(tools: tools)
        guard let skills, ClaudeInvocation.loadSkill(from: skills) != nil else {
            h.fail("the agent-skills folder was not found; pass --skills or set SYNOD_AGENT_SKILLS")
            return 2
        }
        guard let bridge = HelperTools.editorBridge() else {
            h.fail("synod-editor-mcp was not found; build it (swift build)")
            return 2
        }
        setenv("SYNOD_SECRET_SENTINEL", "1", 1)
        setenv("ANTHROPIC_API_KEY", "sentinel-key", 1)

        let rig: HeadlessLearning.Rig
        do { rig = try HeadlessLearning.Rig(module: modulePath) } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("synod-claude-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let hub = EditorMCPHub()
        let model = rig.model
        hub.windows = { [model] }
        model.claude.hub = hub
        defer {
            rig.close()
            try? FileManager.default.removeItem(at: scratch)
        }
        let ctx = Context(rig: rig, hub: hub, fake: fake, skills: skills, bridge: bridge, synod: tools.synod, scratch: scratch)
        let checks = await ctx.runAll()
        return HeadlessChecks.finish(name: "claude-check", checks: checks, module: rig.root.lastPathComponent, args: args)
    }

    // MARK: Support

    @MainActor
    final class Context {
        let rig: HeadlessLearning.Rig
        let hub: EditorMCPHub
        let fake: URL
        let skills: URL
        let bridge: URL
        let synod: URL
        let scratch: URL
        var current: URL
        var model: WorkspaceModel { rig.model }
        var root: URL { rig.root }

        init(rig: HeadlessLearning.Rig, hub: EditorMCPHub, fake: URL, skills: URL, bridge: URL, synod: URL, scratch: URL) {
            self.rig = rig
            self.hub = hub
            self.fake = fake
            self.skills = skills
            self.bridge = bridge
            self.synod = synod
            self.scratch = scratch
            current = fake
            rig.model.claude.isEnabled = { true }
            let box = self
            rig.model.claude.config = {
                ClaudeModel.Config(claude: box.current, model: ClaudeInvocation.defaultModel, skills: skills, synod: synod, bridge: bridge,
                                   timeout: .seconds(60), stopTiming: .init())
            }
        }

        struct Fake {
            let wrapper: URL
            let log: URL
        }

        /// A `claude` that runs `fake-claude` with its log, script and speed set (the app passes it an allowlisted environment only).
        func makeFake(_ name: String, script: [String: Any], slow: Double? = nil) throws -> Fake {
            let log = scratch.appendingPathComponent("\(name).log.json")
            let scriptURL = scratch.appendingPathComponent("\(name).script.json")
            try JSONSerialization.data(withJSONObject: script, options: [.sortedKeys]).write(to: scriptURL)
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var env = "FAKE_CLAUDE_LOG=\(q(log.path)) FAKE_CLAUDE_SCRIPT=\(q(scriptURL.path))"
            if let slow { env += " FAKE_CLAUDE_SLOW=\(slow)" }
            let wrapper = scratch.appendingPathComponent("claude-\(name)")
            try "#!/bin/sh\nexec env \(env) \(q(fake.path)) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
            chmod(wrapper.path, 0o755)
            return Fake(wrapper: wrapper, log: log)
        }

        func readLog(_ f: Fake) -> [String: Any]? {
            guard let d = try? Data(contentsOf: f.log) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }

        /// Module files that a request may change, by path.
        func tree() -> [String: Data] {
            var out: [String: Data] = [:]
            let fm = FileManager.default
            guard let e = fm.enumerator(atPath: root.path) else { return out }
            for case let p as String in e {
                if p.hasPrefix("vendor") || p.hasPrefix("out") || p.hasPrefix(".") || p.contains("/.") || p.contains("/_") || p.hasPrefix("_") { continue }
                if p.hasSuffix(".synod") || p == "synod.mod" || p == "synod.sum", let d = try? Data(contentsOf: root.appendingPathComponent(p)) { out[p] = d }
            }
            return out
        }

        static func session(_ steps: [[String: Any]], result: String = "done") -> [String: Any] {
            ["sessionId": "fake-session-1", "steps": steps, "result": result]
        }

        // MARK: Scenarios

        func runAll() async -> [Check] {
            var checks: [Check] = []
            let h = HeadlessCommands.self
            do {
                try await model.stage?.waitUntilReady()
            } catch {
                h.fail("the stage did not start: \(error.localizedDescription)")
            }
            guard let program = model.workspace.scan().programs.first(where: { $0.relPath == "twopc" }) ?? model.workspace.scan().programs.first else {
                var c = Check(name: "setup")
                c.failures = ["the module has no program"]
                return [c]
            }
            try? await rig.select(program)

            // The user's unsaved edit, on a file Claude is going to change.
            var gate = Check(name: "save gate")
            var argv = Check(name: "argv, cwd and environment")
            var life = Check(name: "config file and socket lifetime")
            var edits = Check(name: "MCP edits, progress and new program")
            var banner = Check(name: "banner and Revert")
            var resume = Check(name: "follow-up uses --resume")
            var stop = Check(name: "Stop")
            var off = Check(name: "setting off never launches")
            func fail(_ c: inout Check, _ m: String) { if c.failures.count < 8 { c.failures.append(m) } }

            let editor = model.editor
            let before = tree()
            let userNote = "# user note\n"
            var expectedBefore = before
            do {
                let doc = try editor.open(file: HeadlessClaude.demo)
                let original = doc.text
                doc.perform(actionName: "Typing") { doc.replace(NSRange(location: doc.positions.utf16Offset(line: 2, col: 1) ?? 0, length: 0), with: userNote) }
                expectedBefore[HeadlessClaude.demo] = Data(doc.text.utf8)
                _ = original
            } catch {
                fail(&gate, "cannot open \(HeadlessClaude.demo): \(error.localizedDescription)")
                return [gate]
            }

            let steps: [[String: Any]] = [
                ["say": "Reading the demo"],
                ["id": "r", "tool": "read_buffer", "arguments": ["path": HeadlessClaude.demo]],
                ["id": "e", "tool": "apply_edits",
                 "arguments": ["path": HeadlessClaude.demo, "version": "${r.version}",
                               "edits": [["line": 2, "col": 1, "endLine": 2, "endCol": 1, "text": "# claude note\n"]]]],
                ["id": "s", "tool": "save_files", "arguments": ["paths": [HeadlessClaude.demo]]],
                ["id": "c", "tool": "create_file", "arguments": ["path": HeadlessClaude.created, "text": HeadlessClaude.createdText]],
                ["id": "d", "tool": "get_diagnostics", "arguments": [:]],
            ]
            let main: Fake
            do { main = try makeFake("main", script: Self.session(steps, result: "Added a note and a demo.")) } catch {
                fail(&gate, error.localizedDescription)
                return [gate]
            }
            current = main.wrapper
            let request = "add a demo"

            // Send is refused until Save All.
            let first = await model.claude.send(request)
            if first != .needsSave([HeadlessClaude.demo]) { fail(&gate, "first send gave \(first)") }
            if FileManager.default.fileExists(atPath: main.log.path) { fail(&gate, "claude ran before the save") }
            if (try? Data(contentsOf: root.appendingPathComponent(HeadlessClaude.demo))) != before[HeadlessClaude.demo] { fail(&gate, "the file was written before the save") }
            let startedAt = ContinuousClock.now
            await model.claude.confirmPending()
            // The request is running: look at the config file while it does.
            var configPath: String?
            var configMode: Int?
            let sawConfig = await HeadlessLearning.wait(20) {
                guard let log = readLog(main), let cfg = (log["configs"] as? [[String: Any]])?.first else { return false }
                configPath = cfg["spec"] as? String
                configMode = (cfg["mode"] as? String).flatMap { Int($0, radix: 8) }
                return configPath != nil
            }
            let socketWhileRunning = await hub.listener.isListening
            let idle = await model.claude.waitUntilIdle(timeout: 60)
            if !idle { fail(&edits, "the request did not finish") }
            let elapsed = ContinuousClock.now - startedAt
            edits.metrics["requestMs"] = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            if (try? Data(contentsOf: root.appendingPathComponent(HeadlessClaude.demo))).map({ String(decoding: $0, as: UTF8.self) })?.contains("# user note") != true {
                fail(&gate, "Save All did not write the user's edit")
            }
            gate.ok = gate.failures.isEmpty

            // argv, cwd, environment.
            guard let log = readLog(main), sawConfig else {
                fail(&argv, "no fake-claude log")
                return [gate, argv]
            }
            let skillMarkdown = ClaudeInvocation.loadSkill(from: skills) ?? ""
            let want = ClaudeInvocation(claude: main.wrapper, request: request, workingDirectory: root, mcpConfig: URL(fileURLWithPath: configPath ?? ""),
                                        skillsFolder: skills, skillMarkdown: skillMarkdown, synod: synod, model: ClaudeInvocation.defaultModel).arguments
            let got = log["argv"] as? [String] ?? []
            if got != want { fail(&argv, "argv differs: \(zip(got, want).first { $0 != $1 }.map { "\($0) vs \($1)" } ?? "length \(got.count) vs \(want.count)")") }
            for needle in ["--mcp-config", "--strict-mcp-config", "--allowedTools", "--disallowedTools"] where !got.contains(needle) { fail(&argv, "no \(needle)") }
            // fake-claude splits the lists on commas and spaces, so `Bash(synod get:*)` arrives in two pieces.
            func pieces(_ list: String) -> [String] { list.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
            if (log["allowedTools"] as? [String]) != pieces(ClaudeInvocation.allowedTools) { fail(&argv, "allowed tools differ") }
            if (log["disallowedTools"] as? [String]) != pieces(ClaudeInvocation.disallowedTools) { fail(&argv, "disallowed tools differ") }
            if pieces(ClaudeInvocation.allowedTools).contains(where: { $0 == "Write" || $0 == "Edit" }) { fail(&argv, "Write or Edit is allowed") }
            let cwd = URL(fileURLWithPath: log["cwd"] as? String ?? "").resolvingSymlinksInPath().path
            if cwd != root.resolvingSymlinksInPath().path { fail(&argv, "cwd is \(cwd)") }
            let env = log["env"] as? [String: String] ?? [:]
            let extra = env.keys.filter { !HeadlessClaude.allowedEnvironment.contains($0) }.sorted()
            if !extra.isEmpty { fail(&argv, "environment has \(extra)") }
            if env["SYNOD_SECRET_SENTINEL"] != nil { fail(&argv, "the sentinel leaked") }
            if env.keys.contains(where: { $0.hasPrefix("ANTHROPIC") }) { fail(&argv, "an API variable leaked") }
            if let path = env["PATH"], !path.hasPrefix(synod.deletingLastPathComponent().path + ":") { fail(&argv, "PATH starts with \(path.prefix(40))") }
            argv.metrics["env"] = Double(env.count)
            argv.ok = argv.failures.isEmpty

            // Config file and socket.
            if configMode != 0o600 { fail(&life, "config mode is \(configMode.map { String($0, radix: 8) } ?? "unknown")") }
            if !socketWhileRunning { fail(&life, "no socket while the request ran") }
            if let configPath, FileManager.default.fileExists(atPath: configPath) { fail(&life, "the config file is still there") }
            if await hub.listener.isListening { fail(&life, "the listener is still up") }
            if let folder = hub.socketFolder, FileManager.default.fileExists(atPath: folder.path) { fail(&life, "the socket folder is still there") }
            let tokens = await hub.table.count
            if tokens != 0 { fail(&life, "\(tokens) tokens are still valid") }
            let servers = ((log["configs"] as? [[String: Any]])?.first?["config"] as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
            if Set(servers.keys) != ["synod-editor", "synod"] { fail(&life, "config servers are \(servers.keys.sorted())") }
            if (log["mcpServers"] as? [[String: Any]])?.allSatisfy({ ($0["status"] as? String) == "connected" }) != true { fail(&life, "an MCP server did not connect") }
            life.ok = life.failures.isEmpty

            // Edits, progress, the new program.
            let calls = (log["calls"] as? [[String: Any]]) ?? []
            let names = calls.compactMap { $0["tool"] as? String }
            if names.contains(where: { $0.hasSuffix("__Write") || $0.hasSuffix("__Edit") || $0 == "Write" || $0 == "Edit" }) { fail(&edits, "a Write or Edit tool appears") }
            if calls.contains(where: { ($0["isError"] as? Bool) == true }) {
                fail(&edits, "a call failed: \(calls.first { ($0["isError"] as? Bool) == true }?["text"] ?? "")")
            }
            let wantProgress = ["Read \(HeadlessClaude.demo)", "Edited \(HeadlessClaude.demo)", "Saved \(HeadlessClaude.demo)", "Created \(HeadlessClaude.created)", "Checked"]
            if model.claude.progress != wantProgress { fail(&edits, "progress is \(model.claude.progress)") }
            if let e = model.claude.errorText { fail(&edits, "error: \(e)") }
            if model.claude.finalText != "Added a note and a demo." { fail(&edits, "final text is \(model.claude.finalText ?? "nil")") }
            var groups = 0
            if let doc = editor.documents[EditorModel.key(HeadlessClaude.demo, .own)] {
                var names: [String] = []
                while doc.undoManager.canUndo, names.count < 20 {
                    names.append(doc.undoManager.undoActionName)
                    doc.undoManager.undo()
                }
                groups = names.filter { $0 == "Claude Edit" }.count
                // Put the buffer back on the disk text for the next steps.
                if let disk = try? String(contentsOf: doc.url, encoding: .utf8) { doc.reload(from: disk) }
            }
            edits.metrics["mcpUndoGroups"] = Double(groups)
            if groups < 1 { fail(&edits, "no \"Claude Edit\" undo group") }
            let wantKey = root.path + "|claudedemo"
            if model.selection?.relPath != "claudedemo" { fail(&edits, "selected \(model.selection?.relPath ?? "nothing")") }
            if editor.current?.file != HeadlessClaude.created { fail(&edits, "the editor shows \(editor.current?.file ?? "nothing")") }
            let ran = await HeadlessLearning.wait(2) { model.loaded?.programKey == wantKey || model.coordinator.isRunning }
            if !ran { fail(&edits, "no run started within 2 s") }
            _ = await HeadlessLearning.wait(15) { model.loaded?.programKey == wantKey && !model.coordinator.isRunning }
            edits.ok = edits.failures.isEmpty

            // Banner and Revert.
            if model.claude.changed != [HeadlessClaude.created, HeadlessClaude.demo].sorted() { fail(&banner, "changed is \(model.claude.changed)") }
            if !model.claude.canRevert { fail(&banner, "Revert is off") }
            if !model.claude.hasBanner { fail(&banner, "no banner") }
            let afterSave = tree()
            if afterSave[HeadlessClaude.created] == nil { fail(&banner, "the new file is not on disk") }
            model.claude.revert()
            let restored = tree()
            if restored != expectedBefore {
                let diff = Set(restored.keys).symmetricDifference(expectedBefore.keys).sorted()
                let changed = restored.keys.filter { expectedBefore[$0] != nil && expectedBefore[$0] != restored[$0] }.sorted()
                fail(&banner, "Revert left differences: \(diff + changed)")
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("claudedemo").path) { fail(&banner, "the added folder is still there") }
            if !model.claude.changed.isEmpty { fail(&banner, "the banner stayed after Revert") }
            banner.ok = banner.failures.isEmpty

            // A second prompt resumes the session.
            do {
                let second = try makeFake("second", script: Self.session([["say": "ok"]]))
                current = second.wrapper
                let r = await model.claude.send("and again")
                if r != .started { fail(&resume, "send gave \(r)") }
                _ = await model.claude.waitUntilIdle(timeout: 30)
                let argv2 = readLog(second)?["argv"] as? [String] ?? []
                if let i = argv2.firstIndex(of: "--resume") {
                    if argv2.indices.contains(i + 1), argv2[i + 1] != "fake-session-1" { fail(&resume, "resumed \(argv2[i + 1])") }
                } else {
                    fail(&resume, "no --resume in \(argv2.count) arguments")
                }
                model.claude.newConversation()
                if model.claude.sessionID != nil { fail(&resume, "New conversation kept the session") }
            } catch {
                fail(&resume, error.localizedDescription)
            }
            resume.ok = resume.failures.isEmpty

            // Stop.
            do {
                let slow = try makeFake("slow", script: Self.session([["say": "waiting"], ["say": "still waiting"]]), slow: 30)
                current = slow.wrapper
                let r = await model.claude.send("take your time")
                if r != .started { fail(&stop, "send gave \(r)") }
                _ = await HeadlessLearning.wait(10) { readLog(slow) != nil }
                try? await Task.sleep(for: .milliseconds(300))
                let t0 = ContinuousClock.now
                model.claude.stop()
                let ended = await model.claude.waitUntilIdle(timeout: 10)
                let d = ContinuousClock.now - t0
                let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                stop.metrics["stopMs"] = ms.rounded()
                if !ended || ms > 3000 { fail(&stop, "the process took \(Int(ms)) ms to stop") }
                if !model.claude.progress.contains("Stopped") { fail(&stop, "no Stopped line") }
                if model.editor.userLocked { fail(&stop, "the buffers stayed locked") }
                if await hub.listener.isListening { fail(&stop, "the listener is still up") }
                if let p = (readLog(slow)?["configs"] as? [[String: Any]])?.first?["spec"] as? String, FileManager.default.fileExists(atPath: p) {
                    fail(&stop, "the config file is still there")
                }
            } catch {
                fail(&stop, error.localizedDescription)
            }
            stop.ok = stop.failures.isEmpty

            // With the setting off nothing is launched.
            do {
                let never = try makeFake("never", script: Self.session([["say": "never"]]))
                current = never.wrapper
                model.claude.isEnabled = { false }
                let r = await model.claude.send("hello")
                model.claude.isEnabled = { true }
                if case .refused = r {} else { fail(&off, "send gave \(r)") }
                try? await Task.sleep(for: .milliseconds(300))
                if FileManager.default.fileExists(atPath: never.log.path) { fail(&off, "claude was launched") }
            } catch {
                fail(&off, error.localizedDescription)
            }
            off.ok = off.failures.isEmpty

            checks = [gate, argv, life, edits, banner, resume, stop, off]
            return checks
        }
    }
}
