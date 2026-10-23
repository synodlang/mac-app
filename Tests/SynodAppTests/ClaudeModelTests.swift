import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

/// A product built next to the test bundle (`fake-claude`, `synod-editor-mcp`), or nil.
private final class BundleAnchor {}

private func builtProduct(_ name: String) -> URL? {
    var dir = Bundle(for: BundleAnchor.self).bundleURL
    for _ in 0..<6 {
        dir = dir.deletingLastPathComponent()
        let u = dir.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return nil
}

private func skillsFolder(file: String = #filePath) -> URL? {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    var candidates = [url.appendingPathComponent("agent-skills")]
    if let p = ProcessInfo.processInfo.environment["SYNOD_AGENT_SKILLS"] { candidates.insert(URL(fileURLWithPath: p), at: 0) }
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("skills/synod/SKILL.md").path) }
}

private let haveEverything: Bool = ToolPaths.repoDeps()?.isUsable == true && builtProduct("fake-claude") != nil
    && builtProduct("synod-editor-mcp") != nil && skillsFolder() != nil

@MainActor
private func makeModel(_ files: [String: String]) throws -> (WorkspaceModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-claude-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "module example.com/t\nsynod 0.2\n".write(to: root.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let model = WorkspaceModel(workspace: try Workspace.open(root), recordRecent: false)
    model.editor.undoGroupsByEvent = false
    model.claude.isEnabled = { true }
    return (model, root)
}

/// A `claude` that runs `fake-claude` with a script (the app passes it an allowlisted environment only).
private func makeFake(_ script: [String: Any], in dir: URL) throws -> (wrapper: URL, log: URL) {
    let log = dir.appendingPathComponent("fake.log.json")
    let scriptURL = dir.appendingPathComponent("fake.script.json")
    try JSONSerialization.data(withJSONObject: script).write(to: scriptURL)
    let wrapper = dir.appendingPathComponent("claude")
    let fake = try #require(builtProduct("fake-claude"))
    try "#!/bin/sh\nexec env FAKE_CLAUDE_LOG='\(log.path)' FAKE_CLAUDE_SCRIPT='\(scriptURL.path)' '\(fake.path)' \"$@\"\n"
        .write(to: wrapper, atomically: true, encoding: .utf8)
    chmod(wrapper.path, 0o755)
    return (wrapper, log)
}

@MainActor @Suite struct ClaudeModelTests {
    @Test func nothingIsLaunchedWhileTheSettingIsOffOrOnTheExamples() async throws {
        let (model, root) = try makeModel(["main/main.synod": "# package main\ndefine main\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.claude.config = { Issue.record("config asked for"); return nil }
        model.claude.isEnabled = { false }
        let off = await model.claude.send("hello")
        guard case .refused = off else { Issue.record("send gave \(off)"); return }
        model.claude.isEnabled = { true }
        let empty = await model.claude.send("   ")
        guard case .refused = empty else { Issue.record("send gave \(empty)"); return }
        #expect(!model.claude.isRunning)
        if let ex = AppEnvironment.shared.examplesURL, let ws = try? Workspace.open(ex) {
            let ro = WorkspaceModel(workspace: ws, recordRecent: false)
            defer { ro.stop() }
            ro.claude.isEnabled = { true }
            ro.claude.config = { Issue.record("config asked for"); return nil }
            let r = await ro.claude.send("hello")
            guard case .refused(let why) = r else { Issue.record("send gave \(r)"); return }
            #expect(why.contains("bundled examples"))
        }
    }

    @Test func unsavedBuffersMustBeSavedFirst() async throws {
        let (model, root) = try makeModel(["main/main.synod": "# package main\ndefine main\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.claude.config = {
            ClaudeModel.Config(claude: URL(fileURLWithPath: "/nonexistent/claude"), model: nil, skills: root, synod: root, bridge: root)
        }
        let doc = try model.editor.open(file: "main/main.synod")
        doc.perform(actionName: "Typing") { doc.replace(NSRange(location: 0, length: 0), with: "# note\n") }
        let r = await model.claude.send("add a node")
        #expect(r == .needsSave(["main/main.synod"]))
        #expect(model.claude.pendingRequest == "add a node")
        #expect(!model.claude.isRunning)
        #expect(try String(contentsOf: root.appendingPathComponent("main/main.synod"), encoding: .utf8) == "# package main\ndefine main\n")
        model.claude.cancelPending()
        #expect(model.claude.pendingRequest == nil && model.claude.pendingFiles.isEmpty)
    }

    @Test(.enabled(if: haveEverything)) func aRequestEditsThroughTheEditorAndRevertRestoresTheFiles() async throws {
        let original = "# package main\ndefine main\n"
        let (model, root) = try makeModel(["main/main.synod": original])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("synod-claude-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: scratch) }
        let script: [String: Any] = [
            "sessionId": "s-1",
            "steps": [
                ["say": "working"],
                ["id": "r", "tool": "read_buffer", "arguments": ["path": "main/main.synod"]],
                ["id": "e", "tool": "apply_edits", "arguments": ["path": "main/main.synod", "version": "${r.version}",
                                                                 "edits": [["line": 2, "col": 1, "endLine": 2, "endCol": 1, "text": "# claude\n"]]]],
                ["id": "c", "tool": "create_file", "arguments": ["path": "extra/extra.synod", "text": "# package extra\n"]],
            ],
            "result": "all done",
        ]
        let fake = try makeFake(script, in: scratch)
        let hub = EditorMCPHub()
        hub.windows = { [model] }
        model.claude.hub = hub
        let tools = try #require(ToolPaths.repoDeps())
        let skills = try #require(skillsFolder())
        let bridge = try #require(builtProduct("synod-editor-mcp"))
        model.claude.config = {
            ClaudeModel.Config(claude: fake.wrapper, model: "claude-opus-5-5", skills: skills, synod: tools.synod, bridge: bridge, timeout: .seconds(60))
        }
        #expect(await model.claude.send("do it") == .started)
        #expect(model.editor.userLocked)
        #expect(await model.claude.waitUntilIdle(timeout: 60))
        // isRunning turns false before the request's changes are worked out, so wait for them (bounded).
        let settled = await poll(timeout: 30) { model.claude.hasBanner && !model.editor.userLocked && model.claude.finalText != nil }
        #expect(settled)
        #expect(!model.editor.userLocked)
        #expect(model.claude.progress == ["Read main/main.synod", "Edited main/main.synod", "Created extra/extra.synod"])
        #expect(model.claude.finalText == "all done")
        #expect(model.claude.errorText == nil)
        #expect(model.claude.sessionID == "s-1")
        // The edit is an unsaved buffer change; the new file is on disk.
        let doc = try #require(model.editor.documents["own:main/main.synod"])
        #expect(doc.isDirty && doc.text == "# package main\n# claude\ndefine main\n")
        #expect(doc.undoManager.undoActionName == "Claude Edit")
        #expect(try String(contentsOf: root.appendingPathComponent("main/main.synod"), encoding: .utf8) == original)
        #expect(model.claude.changed == ["extra/extra.synod", "main/main.synod"])
        #expect(model.claude.unsavedLeft && model.claude.canRevert)
        // Nothing of the session is left behind.
        let listenerGone = await pollAsync(timeout: 10) { await !hub.listener.isListening }
        #expect(listenerGone)
        #expect(await hub.table.count == 0)
        // Revert drops the unsaved edit and removes the added file.
        model.claude.revert()
        #expect(doc.text == original && !doc.isDirty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("extra").path))
        #expect(model.claude.changed.isEmpty)
    }

    /// Polls `condition` every 20 ms until it holds or `timeout` seconds pass.
    private func poll(timeout: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func pollAsync(timeout: Double, _ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while await !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return await condition()
    }

    @Test func newConversationForgetsTheSession() async throws {
        let (model, root) = try makeModel(["main/main.synod": "# package main\ndefine main\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.claude.newConversation()
        #expect(model.claude.sessionID == nil && model.claude.progress.isEmpty && !model.claude.hasBanner)
    }

    @Test func theExplainPresetNeedsARun() async throws {
        let (model, root) = try makeModel(["main/main.synod": "# package main\ndefine main\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let r = await model.claude.explainRun()
        guard case .refused = r else { Issue.record("explainRun gave \(r)"); return }
        #expect(ClaudeInvocation.explainRunPrompt(program: "main", mainFile: "main/main.synod")
                == "Explain this run: run \"synod run main --summary\", then add lesson.Note lines to define main in main/main.synod that caption what happens, at the times it happens. Do not change the behaviour.")
    }
}
