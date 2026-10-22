import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

@MainActor
private func makeModel(_ files: [String: String]) throws -> (WorkspaceModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-mcp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "module example.com/t\nsynod 0.2\n".write(to: root.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let model = WorkspaceModel(workspace: try Workspace.open(root), recordRecent: false)
    model.editor.undoGroupsByEvent = false
    return (model, root)
}

private let haveCompiler: Bool = ToolPaths.repoDeps()?.isUsable == true
private let haveExamples: Bool = ToolPaths.repoDeps()?.examples != nil

@MainActor
private func expectFailure(_ code: EditorErrorCode, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected \(code.rawValue)")
    } catch let e as EditorToolError {
        #expect(e.code == code, "got \(e)")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@MainActor @Suite struct EditorMCPTests {
    @Test func readBufferReturnsTheUnsavedTextAndTheDiskTextWhenClosed() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\none\ntwo\n", "lib/other.synod": "# package lib\nx\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let s = EditorMCPService(model: model, kind: .promptBar)
        let closed = try await s.readBuffer(path: "lib/other.synod", startLine: nil, endLine: nil)
        #expect(closed.version == 0 && !closed.dirty && closed.text == "# package lib\nx\n" && closed.lineCount == 2)
        let doc = try model.editor.open(file: "lib/lib.synod")
        doc.perform(actionName: "Typing") { doc.replace(NSRange(location: 0, length: 0), with: "# note\n") }
        let r = try await s.readBuffer(path: "lib/lib.synod", startLine: nil, endLine: nil)
        #expect(r.text == "# note\n# package lib\none\ntwo\n" && r.dirty && r.version == doc.version && r.lineCount == 4)
        let part = try await s.readBuffer(path: "lib/lib.synod", startLine: 3, endLine: 99)
        #expect(part.text == "one\ntwo\n" && part.startLine == 3 && part.endLine == 4)
        #expect(try String(contentsOf: root.appendingPathComponent("lib/lib.synod"), encoding: .utf8) == "# package lib\none\ntwo\n")
    }

    @Test func applyEditsIsOneUndoGroupNamedClaudeEdit() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\none\ntwo\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let s = EditorMCPService(model: model, kind: .promptBar)
        let before = try await s.readBuffer(path: "lib/lib.synod", startLine: nil, endLine: nil)
        // Two edits, given in ascending order; they land together.
        let r = try await s.applyEdits(path: "lib/lib.synod", version: before.version, edits: [
            EditorTextEdit(line: 2, col: 1, endLine: 2, endCol: 4, text: "1"),
            EditorTextEdit(line: 3, col: 1, endLine: 3, endCol: 4, text: "2"),
        ])
        let doc = try #require(model.editor.documents["own:lib/lib.synod"])
        #expect(doc.text == "# package lib\n1\n2\n")
        #expect(r.dirty && r.version == doc.version)
        #expect(doc.undoManager.undoActionName == "Claude Edit")
        doc.undoManager.undo()
        #expect(doc.text == "# package lib\none\ntwo\n")
        #expect(!doc.isDirty)
        #expect(!doc.undoManager.canUndo)
    }

    @Test func versionRangeOverlapAndPathErrors() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\none\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let s = EditorMCPService(model: model, kind: .promptBar)
        let edit = EditorTextEdit(line: 2, col: 1, endLine: 2, endCol: 2, text: "x")
        await expectFailure(.versionMismatch) { _ = try await s.applyEdits(path: "lib/lib.synod", version: 7, edits: [edit]) }
        await expectFailure(.badRange) { _ = try await s.applyEdits(path: "lib/lib.synod", version: 0, edits: [EditorTextEdit(line: 9, col: 1, endLine: 9, endCol: 1, text: "x")]) }
        await expectFailure(.badRange) { _ = try await s.applyEdits(path: "lib/lib.synod", version: 0, edits: [EditorTextEdit(line: 2, col: 3, endLine: 2, endCol: 1, text: "x")]) }
        await expectFailure(.badRange) {
            _ = try await s.applyEdits(path: "lib/lib.synod", version: 0, edits: [
                EditorTextEdit(line: 2, col: 1, endLine: 2, endCol: 3, text: "x"), EditorTextEdit(line: 2, col: 2, endLine: 2, endCol: 4, text: "y")])
        }
        await expectFailure(.outsideModule) { _ = try await s.readBuffer(path: "../x", startLine: nil, endLine: nil) }
        await expectFailure(.outsideModule) { _ = try await s.readBuffer(path: "/etc/hosts", startLine: nil, endLine: nil) }
        await expectFailure(.outsideModule) { _ = try await s.readBuffer(path: "lib/../../x", startLine: nil, endLine: nil) }
        await expectFailure(.notFound) { _ = try await s.readBuffer(path: "nope.synod", startLine: nil, endLine: nil) }
        await expectFailure(.readOnly) { _ = try await s.createFile(path: "vendor/m/m.synod", text: "# package m\n") }
        await expectFailure(.exists) { _ = try await s.createFile(path: "lib/lib.synod", text: "# package lib\n") }
        #expect(model.editor.documents["own:lib/lib.synod"]?.isDirty != true)
    }

    @Test func aSymlinkOutOfTheModuleIsOutsideTheModule() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\n"])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("synod-mcp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret\n".write(to: outside.appendingPathComponent("s.synod"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        defer { model.stop(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let s = EditorMCPService(model: model, kind: .promptBar)
        await expectFailure(.outsideModule) { _ = try await s.readBuffer(path: "link/s.synod", startLine: nil, endLine: nil) }
    }

    @Test(.enabled(if: haveExamples)) func aReadOnlyWorkspaceRefusesEveryWrite() async throws {
        let ex = try #require(AppEnvironment.shared.examplesURL)
        let model = WorkspaceModel(workspace: try Workspace.open(ex), recordRecent: false)
        defer { model.stop() }
        #expect(model.isReadOnly)
        let s = EditorMCPService(model: model, kind: .promptBar)
        let read = try await s.readBuffer(path: "gossip/gossip.synod", startLine: 1, endLine: 2)
        #expect(read.readOnly && read.text.hasPrefix("# package gossip"))
        await expectFailure(.readOnly) { _ = try await s.applyEdits(path: "gossip/gossip.synod", version: 0, edits: [EditorTextEdit(line: 1, col: 1, endLine: 1, endCol: 1, text: "x")]) }
        await expectFailure(.readOnly) { _ = try await s.replaceBuffer(path: "gossip/gossip.synod", version: 0, text: "x") }
        await expectFailure(.readOnly) { _ = try await s.createFile(path: "new/new.synod", text: "x") }
        await expectFailure(.readOnly) { _ = try await s.saveFiles(paths: ["gossip/gossip.synod"]) }
        let listed = try await s.listFiles()
        #expect(listed.contains { $0.path == "gossip/gossip.synod" && $0.readOnly })
    }

    @Test func externalWritesAreBusyWhileAPromptBarRequestRuns() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\none\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let external = EditorMCPService(model: model, kind: .external)
        let bar = EditorMCPService(model: model, kind: .promptBar)
        model.claude.isRunning = true
        defer { model.claude.isRunning = false }
        let edit = EditorTextEdit(line: 2, col: 1, endLine: 2, endCol: 2, text: "x")
        await expectFailure(.busy) { _ = try await external.applyEdits(path: "lib/lib.synod", version: 0, edits: [edit]) }
        await expectFailure(.busy) { _ = try await external.replaceBuffer(path: "lib/lib.synod", version: 0, text: "x") }
        await expectFailure(.busy) { _ = try await external.createFile(path: "a/a.synod", text: "x") }
        await expectFailure(.busy) { _ = try await external.saveFiles(paths: ["lib/lib.synod"]) }
        // Reads are fine for it, and the prompt bar's own session may write.
        _ = try await external.readBuffer(path: "lib/lib.synod", startLine: nil, endLine: nil)
        _ = try await bar.applyEdits(path: "lib/lib.synod", version: 0, edits: [edit])
    }

    @Test(.enabled(if: haveCompiler)) func saveFilesFormatsAndWritesAndDiagnosticsSeeUnsavedEdits() async throws {
        let tidy = "# package lib\nNode has\n  set Count to 0\n\ndefine [n: Node] Bump\n  set n.Count to (n.Count plus 1)\n\ndefine [n: Node] Twice\n  n.Bump\n  n.Bump\n"
        let untidy = "# package lib\nNode has\n  set Count   to 0\n\n\ndefine [n: Node] Bump\n  set n.Count to  (n.Count plus 1)\n\ndefine [n: Node] Twice\n  n.Bump\n  n.Bump\n\n\n"
        let (model, root) = try makeModel(["lib/lib.synod": tidy])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let s = EditorMCPService(model: model, kind: .promptBar)
        let clean = try await s.diagnostics(path: nil, fresh: true)
        #expect(!clean.stale)
        #expect(clean.diagnostics.isEmpty, "\(clean.diagnostics)")
        // A misspelled phrase, in the buffer only.
        _ = try await s.applyEdits(path: "lib/lib.synod", version: 0, edits: [EditorTextEdit(line: 10, col: 5, endLine: 10, endCol: 9, text: "Bunp")])
        let r = try await s.diagnostics(path: "lib/lib.synod", fresh: true)
        #expect(r.diagnostics.contains { $0.code == "unknown-phrase" && $0.path == "lib/lib.synod" }, "\(r.diagnostics)")
        #expect(try String(contentsOf: root.appendingPathComponent("lib/lib.synod"), encoding: .utf8) == tidy)
        let other = try await s.diagnostics(path: "lib/none.synod", fresh: false)
        #expect(other.diagnostics.isEmpty)
        // Fix it with a replace, make it untidy, save: the file is written formatted.
        let doc = try #require(model.editor.documents["own:lib/lib.synod"])
        _ = try await s.replaceBuffer(path: "lib/lib.synod", version: doc.version, text: untidy)
        let saved = try await s.saveFiles(paths: ["lib/lib.synod"])
        #expect(saved.failed.isEmpty && saved.saved.count == 1 && saved.saved[0].formatted)
        #expect(try String(contentsOf: root.appendingPathComponent("lib/lib.synod"), encoding: .utf8) == tidy)
        #expect(!doc.isDirty)
        let made = try await s.createFile(path: "extra/e.synod", text: untidy.replacingOccurrences(of: "lib", with: "extra"))
        #expect(made.formatted)
        #expect(model.editor.current?.file == "extra/e.synod")
    }

    @Test func theLogSinkReceivesNoText() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\nSECRET-BUFFER-TEXT\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let hub = EditorMCPHub(baseDirectory: FileManager.default.temporaryDirectory)
        let box = MCPLogBox()
        hub.logSink = { e, k in box.add(e, k) }
        let registry = hub.registry(model: model, kind: .promptBar)
        let read = await registry.call(name: "read_buffer", arguments: .object([JSONMember(key: "path", value: .string("lib/lib.synod"))]))
        #expect(read.text.contains("SECRET-BUFFER-TEXT"))
        let bad = await registry.call(name: "read_buffer", arguments: .object([JSONMember(key: "path", value: .string("../x"))]))
        #expect(bad.isError)
        let entries = box.entries
        #expect(entries.count == 2)
        #expect(entries[0].0.tool == "read_buffer" && entries[0].0.path == "lib/lib.synod" && entries[0].0.errorCode == nil)
        #expect(entries[1].0.errorCode == "outside-module")
        #expect(!"\(entries)".contains("SECRET-BUFFER-TEXT"))
    }

    @Test func aClosedWindowAnswersNotFound() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let s = EditorMCPService(model: model, kind: .external)
        model.stop()
        await expectFailure(.notFound) { _ = try await s.readBuffer(path: "lib/lib.synod", startLine: nil, endLine: nil) }
        await expectFailure(.notFound) { _ = try await s.listFiles() }
        await expectFailure(.notFound) { _ = try await s.diagnostics(path: nil, fresh: false) }
    }

    @Test func pathValidationAndLines() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        #expect(try EditorMCPService.validate("a//b/./c.synod", root: root) == "a/b/c.synod")
        #expect(throws: EditorToolError.self) { try EditorMCPService.validate("", root: root) }
        #expect(throws: EditorToolError.self) { try EditorMCPService.validate("a/../..", root: root) }
        #expect(EditorMCPService.lines(of: "") == [])
        #expect(EditorMCPService.lines(of: "a\n") == ["a\n"])
        #expect(EditorMCPService.lines(of: "a\n\nb") == ["a\n", "\n", "b"])
        #expect(EditorModel.isWritablePath("a/b.synod"))
        #expect(EditorModel.isWritablePath("synod.mod"))
        #expect(!EditorModel.isWritablePath("sub/synod.mod"))
        #expect(!EditorModel.isWritablePath("vendor/x/x.synod"))
        #expect(!EditorModel.isWritablePath("out/x.synod"))
        #expect(!EditorModel.isWritablePath("a/.hidden/x.synod"))
        #expect(!EditorModel.isWritablePath("a/_x/x.synod"))
        #expect(!EditorModel.isWritablePath("README.md"))
    }

    @Test func theCopiedCommandHasTheExactShape() {
        let token = String(repeating: "ab", count: 32)
        let line = EditorMCPHub.addCommand(token: token, bridge: "/Applications/Synod.app/Contents/Helpers/synod-editor-mcp",
                                           socket: "/var/t/synod-mcp-1a2b3c4d/editor.sock", workspace: "/Users/me/my \"mod\"")
        let want = "claude mcp add --scope local synod-editor -e SYNOD_EDITOR_TOKEN=\(token) -- "
            + "\"/Applications/Synod.app/Contents/Helpers/synod-editor-mcp\" --socket \"/var/t/synod-mcp-1a2b3c4d/editor.sock\" "
            + "--workspace \"/Users/me/my \\\"mod\\\"\""
        #expect(line == want)
    }
}

@MainActor @Suite struct EditorMCPHubTests {
    @Test func aRequestHoldsTheSocketAndTheConfigFileUntilItEnds() async throws {
        let (model, root) = try makeModel(["lib/lib.synod": "# package lib\n"])
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let base = URL(fileURLWithPath: "/tmp/sh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let hub = EditorMCPHub(baseDirectory: base)
        hub.windows = { [model] }
        let session = try await hub.beginRequest(for: model, synod: URL(fileURLWithPath: "/bin/synod"), bridge: URL(fileURLWithPath: "/bin/bridge"))
        func mode(_ p: String) -> Int? { var st = stat(); return stat(p, &st) == 0 ? Int(st.st_mode & 0o777) : nil }
        #expect(mode(session.config.url.path) == 0o600)
        #expect(mode(session.socket.path) == 0o600)
        #expect(mode(session.socket.deletingLastPathComponent().path) == 0o700)
        let json = try String(contentsOf: session.config.url, encoding: .utf8)
        #expect(json.contains("\"SYNOD_EDITOR_TOKEN\":\"\(session.token)\""))
        #expect(json.contains("\"command\":\"/bin/bridge\"") && json.contains("\"args\":[\"mcp\"]"))
        #expect(await hub.table.count == 1)
        await hub.endRequest(session)
        #expect(!FileManager.default.fileExists(atPath: session.config.url.path))
        #expect(!FileManager.default.fileExists(atPath: session.socket.path))
        #expect(!FileManager.default.fileExists(atPath: session.socket.deletingLastPathComponent().path))
        #expect(await hub.table.count == 0)
        #expect(await !hub.listener.isListening)
    }

    @Test func externalAccessIsOffAtLaunchAndNeverStored() async throws {
        let hub = EditorMCPHub(baseDirectory: FileManager.default.temporaryDirectory)
        #expect(!hub.externalEnabled && hub.externalToken == nil)
        #expect(await !hub.listener.isListening)
        await hub.setExternal(true)
        let first = try #require(hub.externalToken)
        #expect(hub.externalEnabled && first.count == 64)
        #expect(await hub.listener.isListening)
        await hub.disconnectExternal()
        let second = try #require(hub.externalToken)
        #expect(second != first && second.count == 64)
        await hub.setExternal(false)
        #expect(!hub.externalEnabled && hub.externalToken == nil)
        #expect(await !hub.listener.isListening)
        #expect(UserDefaults.standard.object(forKey: "externalEditorAccess") == nil)
    }
}
