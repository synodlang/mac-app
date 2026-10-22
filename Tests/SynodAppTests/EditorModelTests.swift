import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

@MainActor
private func makeWorkspace(_ files: [String: String]) throws -> (Workspace, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-editor-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "module example.com/t\nsynod 0.2\n".write(to: root.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return (try Workspace.open(root), root)
}

@MainActor
private func makeEditor(_ files: [String: String], readOnly: Bool = false) throws -> (EditorModel, Workspace, URL) {
    let (ws, root) = try makeWorkspace(files)
    // No compiler: checks and fmt are skipped (the runner closure returns nil).
    let editor = EditorModel(workspace: ws, ownReadOnly: readOnly, runner: { nil })
    editor.undoGroupsByEvent = false
    return (editor, ws, root)
}

@MainActor @Suite struct EditorModelTests {
    @Test func editingMarksTheBufferDirtyAndSaveWritesTheFile() async throws {
        let (editor, ws, root) = try makeEditor(["main/main.synod": "# package main\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "main/main.synod")
        #expect(!doc.isDirty)
        try await editor.applyEdit(file: "main/main.synod") { $0 + "define main\n" }
        #expect(doc.isDirty)
        #expect(try String(contentsOf: ws.url(forRelative: "main/main.synod")) == "# package main\n")   // not written yet
        let result = try await editor.save(file: "main/main.synod")
        #expect(result == .saved(formatted: false))
        #expect(!doc.isDirty)
        #expect(try String(contentsOf: ws.url(forRelative: "main/main.synod")) == "# package main\ndefine main\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))
    }

    @Test func applyEditIsOneUndoableChange() async throws {
        let (editor, _, root) = try makeEditor(["a.synod": "one\ntwo\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        try await editor.applyEdit(file: "a.synod", actionName: "Break it") { $0.replacingOccurrences(of: "two", with: "2") + "three\n" }
        #expect(doc.text == "one\n2\nthree\n")
        #expect(doc.undoManager.undoActionName == "Break it")
        doc.undoManager.undo()
        #expect(doc.text == "one\ntwo\n")
        #expect(!doc.isDirty)
    }

    @Test func aTransformThatThrowsLeavesTheBufferAlone() async throws {
        struct Boom: Error {}
        let (editor, _, root) = try makeEditor(["a.synod": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        await #expect(throws: Boom.self) { try await editor.applyEdit(file: "a.synod") { _ in throw Boom() } }
        #expect(doc.text == "one\n")
        #expect(!doc.isDirty)
    }

    @Test func readOnlyBuffersRefuseEditsAndSaves() async throws {
        let (editor, _, root) = try makeEditor(["vendor/m@v1/x.synod": "x\n", "a.synod": "a\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let vendored = try editor.open(file: "vendor/m@v1/x.synod")
        #expect(vendored.isReadOnly)
        await #expect(throws: EditorModel.EditorError.readOnly("vendor/m@v1/x.synod")) {
            try await editor.applyEdit(file: "vendor/m@v1/x.synod") { $0 + "y" }
        }
        await #expect(throws: EditorModel.EditorError.readOnly("vendor/m@v1/x.synod")) { try await editor.save(file: "vendor/m@v1/x.synod") }
        #expect(!(try editor.open(file: "a.synod")).isReadOnly)
        let (ro, _, root2) = try makeEditor(["a.synod": "a\n"], readOnly: true)
        defer { try? FileManager.default.removeItem(at: root2) }
        #expect(try ro.open(file: "a.synod").isReadOnly)
    }

    @Test func aCleanBufferReloadsWhenTheFileChangesOutside() async throws {
        let (editor, ws, root) = try makeEditor(["a.synod": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        try "two\n".write(to: ws.url(forRelative: "a.synod"), atomically: true, encoding: .utf8)
        editor.diskChanged()
        #expect(doc.text == "two\n")
        #expect(!doc.isDirty)
        #expect(doc.conflict == nil)
    }

    @Test func aDirtyBufferGetsAConflictAndKeepMineKeepsItsText() async throws {
        let (editor, ws, root) = try makeEditor(["a.synod": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        try await editor.applyEdit(file: "a.synod") { $0 + "mine\n" }
        try "theirs\n".write(to: ws.url(forRelative: "a.synod"), atomically: true, encoding: .utf8)
        editor.diskChanged()
        #expect(doc.conflict == "theirs\n")
        #expect(doc.text == "one\nmine\n")
        editor.keepMine(doc)
        #expect(doc.conflict == nil)
        #expect(doc.isDirty)                       // still differs from the new disk text
        #expect(doc.text == "one\nmine\n")
        // The other choice: reload.
        try "again\n".write(to: ws.url(forRelative: "a.synod"), atomically: true, encoding: .utf8)
        editor.diskChanged()
        editor.reloadFromDisk(doc)
        #expect(doc.text == "again\n")
        #expect(!doc.isDirty)
    }

    @Test func ourOwnSaveIsNotAnOutsideChange() async throws {
        let (editor, _, root) = try makeEditor(["a.synod": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        try await editor.applyEdit(file: "a.synod") { $0 + "more\n" }
        try await editor.save(file: "a.synod")
        editor.diskChanged()
        #expect(doc.conflict == nil)
        #expect(doc.text == "one\nmore\n")
    }

    @Test func aFixAppliesToItsOwnBufferOnlyWhenTheCheckIsCurrent() throws {
        let (editor, _, root) = try makeEditor(["a.synod": "sim.Crsh old\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "a.synod")
        let help = CheckReport.Help.test(edits: [(1, 1, 1, 9, "sim.Crash")])
        let fix = EditorFix(file: "a.synod", origin: .own, text: "fix", help: help)
        // Not checked yet: refused, nothing changes.
        #expect(throws: EditorModel.EditorError.stale) { try editor.apply(fix) }
        #expect(doc.text == "sim.Crsh old\n")
        doc.setCheck(tokens: nil, diagnostics: [], forVersion: doc.version)
        try editor.apply(fix)
        #expect(doc.text == "sim.Crash old\n")
        #expect(doc.isDirty)
        // After the text changed, the old fix is stale again.
        #expect(throws: EditorModel.EditorError.stale) { try editor.apply(fix) }
    }

    @Test func goToDefinitionMapsVendoredFilesAndOpensTheTarget() throws {
        let (editor, _, root) = try makeEditor([
            "main/main.synod": "# package main\nuse foo\n",
            "pkg/pkg.synod": "# package pkg\ndefine Thing\n",
            "vendor/example.com/dep@v1.0.0/dep.synod": "# package dep\ndefine Dep\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "main/main.synod")
        let tokens = [
            SynodToken(line: 2, col: 5, len: 3, role: .phrase, def: TokenDefinition(file: "pkg/pkg.synod", line: 2, col: 8)),
            SynodToken(line: 1, col: 1, len: 3, role: .phrase, def: TokenDefinition(file: "example.com/dep@v1.0.0/dep.synod", line: 2, col: 8)),
            SynodToken(line: 1, col: 5, len: 4, role: .language),
        ]
        doc.setCheck(tokens: FileTokens(file: "main/main.synod", tokens: tokens.sorted { ($0.line, $0.col) < ($1.line, $1.col) }),
                     diagnostics: [], forVersion: doc.version)
        let use = try #require(doc.tokens.first { $0.def?.file == "pkg/pkg.synod" })
        #expect(try editor.goToDefinition(in: doc, atOffset: use.range.location + 1))
        #expect(editor.current?.file == "pkg/pkg.synod")
        #expect(editor.reveal?.line == 2 && editor.reveal?.col == 8)
        let vend = try #require(doc.tokens.first { $0.def?.file.hasPrefix("example.com") == true })
        #expect(try editor.goToDefinition(in: doc, atOffset: vend.range.location))
        #expect(editor.current?.file == "vendor/example.com/dep@v1.0.0/dep.synod")
        #expect(editor.current?.isReadOnly == true)
        let kw = try #require(doc.tokens.first { $0.role == .language })
        #expect(try !editor.goToDefinition(in: doc, atOffset: kw.range.location))
    }

    @Test func siblingFilesListTheFolder() throws {
        let (editor, _, root) = try makeEditor(["p/a.synod": "a", "p/b.synod": "b", "p/readme.md": "x", "q/c.synod": "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try editor.open(file: "p/b.synod")
        #expect(editor.siblingFiles(of: doc) == ["p/a.synod", "p/b.synod"])
    }

    @Test func dirtyDocumentsListsOnlyEditedBuffers() async throws {
        let (editor, _, root) = try makeEditor(["a.synod": "a\n", "b.synod": "b\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        try editor.open(file: "a.synod")
        try editor.open(file: "b.synod")
        try await editor.applyEdit(file: "b.synod") { $0 + "x" }
        #expect(editor.dirtyDocuments.map(\.file) == ["b.synod"])
    }
}
