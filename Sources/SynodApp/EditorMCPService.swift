import AppKit
import Foundation
import Observation
import OSLog
import SynodCore

/// The editor tools of the app (decision 99) over a window's `EditorModel`. Every call runs on the
/// main actor, so Claude and the user see one buffer. A prompt-bar session may write while its
/// request runs; an external Terminal session gets `busy` for writes while a request runs.
@MainActor
struct EditorMCPService: EditorService {
    enum Kind: String, Sendable {
        case promptBar = "prompt-bar"
        case external
    }

    let model: WorkspaceModel
    let kind: Kind

    private var editor: EditorModel { model.editor }
    private var root: URL { model.workspace.root }

    // MARK: Paths

    /// A module-relative slash path, or `outside-module` / `bad-arguments`.
    static func validate(_ path: String, root: URL) throws -> String {
        if path.isEmpty || path.contains("\0") { throw EditorToolError(.badArguments, "path is empty") }
        if path.hasPrefix("/") || path.hasPrefix("~") { throw EditorToolError(.outsideModule, "path must be relative to the module root") }
        var parts: [String] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == ".." { throw EditorToolError(.outsideModule, "path leaves the module") }
            if c == "." { continue }
            parts.append(String(c))
        }
        if parts.isEmpty { throw EditorToolError(.badArguments, "path names no file") }
        let rel = parts.joined(separator: "/")
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = root.appendingPathComponent(rel).resolvingSymlinksInPath().path
        guard full == base || full.hasPrefix(base + "/") else { throw EditorToolError(.outsideModule, "path leaves the module") }
        return rel
    }

    private func rel(_ path: String) throws -> String { try Self.validate(path, root: root) }

    private func requireNotBusy() throws {
        if kind == .external, model.claude.isRunning {
            throw EditorToolError(.busy, "a prompt-bar request is running in this window; try again when it is done")
        }
    }

    private func isReadOnly(_ file: String) -> Bool {
        editor.ownReadOnly || file.hasPrefix("vendor/") || !EditorModel.isWritablePath(file)
    }

    // MARK: Reading

    func listFiles() async throws -> [EditorFileInfo] {
        var paths: [String] = []
        let fm = FileManager.default
        func walk(_ dir: String) {
            let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for name in names {
                if name.hasPrefix(".") || name.hasPrefix("_") { continue }
                let childRel = dir.isEmpty ? name : dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: root.appendingPathComponent(childRel).path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if name == "vendor" || name == "out" { continue }
                    walk(childRel)
                } else if name.hasSuffix(".synod") || (dir.isEmpty && name == "synod.mod") {
                    paths.append(childRel)
                }
            }
        }
        walk("")
        return paths.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.map { p in
            let doc = editor.documents[EditorModel.key(p, .own)]
            return EditorFileInfo(path: p, open: doc != nil, dirty: doc?.isDirty ?? false, readOnly: isReadOnly(p), version: doc?.version ?? 0)
        }
    }

    func readBuffer(path: String, startLine: Int?, endLine: Int?) async throws -> EditorBufferSlice {
        let file = try rel(path)
        let text: String
        var version = 0
        var dirty = false
        if let doc = editor.documents[EditorModel.key(file, .own)] {
            text = doc.text
            version = doc.version
            dirty = doc.isDirty
        } else {
            let url = root.appendingPathComponent(file)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                throw EditorToolError(.notFound, "\(file) does not exist")
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            if size > 1_048_576 { throw EditorToolError(.tooLarge, "\(file) is larger than 1 MB") }
            guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
                throw EditorToolError(.badArguments, "\(file) is not UTF-8 text")
            }
            text = s
        }
        if text.utf8.count > 1_048_576 { throw EditorToolError(.tooLarge, "\(file) is larger than 1 MB") }
        let lines = Self.lines(of: text)
        let count = lines.count
        let start = count == 0 ? 1 : min(max(startLine ?? 1, 1), count)
        let end = count == 0 ? 0 : min(max(endLine ?? count, start), count)
        let slice = count == 0 ? "" : lines[(start - 1)..<end].joined()
        return EditorBufferSlice(path: file, version: version, dirty: dirty, readOnly: isReadOnly(file), lineCount: count,
                                 startLine: start, endLine: end, text: slice)
    }

    /// The lines of `text`, each with its newline; a final newline does not start another line.
    static func lines(of text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
            return parts.map { $0 + "\n" }
        }
        return parts.enumerated().map { $0.offset < parts.count - 1 ? $0.element + "\n" : $0.element }
    }

    func diagnostics(path: String?, fresh: Bool) async throws -> EditorDiagnosticsResult {
        let filter = try path.map { try rel($0) }
        var report: CheckReport?
        var stale = false
        if fresh || editor.moduleReport == nil {
            do {
                (report, stale) = try await editor.checkModule(timeout: .seconds(5))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as EditorToolError {
                throw e
            } catch {
                throw EditorToolError(.badArguments, "the check could not run: \(error.localizedDescription)")
            }
        } else {
            report = editor.moduleReport
            stale = true
        }
        guard let report else { return EditorDiagnosticsResult(stale: true, diagnostics: []) }
        let all = report.diagnostics.filter { filter == nil || $0.file == filter }.map {
            EditorDiagnostic(path: $0.file, line: $0.line, col: $0.col, endLine: $0.end.line, endCol: $0.end.col, severity: $0.severity,
                             code: $0.code, message: $0.message, hint: $0.hint)
        }
        return EditorDiagnosticsResult(stale: stale, diagnostics: all)
    }

    func selection() async throws -> EditorSelectionInfo {
        guard let doc = editor.current, doc.origin == .own else {
            return EditorSelectionInfo(path: nil, version: nil, caret: nil, selections: [])
        }
        let positions = doc.positions
        let sel = doc.selection
        let caret = positions.position(utf16Offset: sel.location).map { EditorPosition(line: $0.line, col: $0.col) }
        var ranges: [EditorSelectionRange] = []
        if sel.length > 0, NSMaxRange(sel) <= positions.utf16Length,
           let a = positions.position(utf16Offset: sel.location), let b = positions.position(utf16Offset: NSMaxRange(sel)) {
            ranges.append(EditorSelectionRange(line: a.line, col: a.col, endLine: b.line, endCol: b.col,
                                               text: (doc.text as NSString).substring(with: sel)))
        }
        return EditorSelectionInfo(path: doc.file, version: doc.version, caret: caret, selections: ranges)
    }

    // MARK: Writing

    func applyEdits(path: String, version: Int, edits: [EditorTextEdit]) async throws -> EditorEditResult {
        try requireNotBusy()
        let file = try rel(path)
        let v = try editor.applyEdits(path: file, version: version, edits: edits)
        return EditorEditResult(path: file, version: v, dirty: editor.documents[EditorModel.key(file, .own)]?.isDirty ?? true)
    }

    func replaceBuffer(path: String, version: Int, text: String) async throws -> EditorEditResult {
        try requireNotBusy()
        let file = try rel(path)
        let v = try editor.replaceBuffer(path: file, version: version, text: text)
        return EditorEditResult(path: file, version: v, dirty: editor.documents[EditorModel.key(file, .own)]?.isDirty ?? true)
    }

    func createFile(path: String, text: String) async throws -> EditorCreateResult {
        try requireNotBusy()
        let file = try rel(path)
        let r = try await editor.createFile(path: file, text: text)
        return EditorCreateResult(path: file, version: r.version, formatted: r.formatted)
    }

    func saveFiles(paths: [String]) async throws -> EditorSaveResult {
        try requireNotBusy()
        if editor.ownReadOnly { throw EditorToolError(.readOnly, "bundled examples; copy them to a folder first") }
        let files = try paths.map { try rel($0) }
        var saved: [EditorSavedFile] = []
        var failed: [EditorSaveFailure] = []
        for file in files {
            if isReadOnly(file) {
                failed.append(EditorSaveFailure(path: file, message: "read-only: \(file) is not a writable Synod file"))
                continue
            }
            do {
                let result = try await editor.save(file: file)
                var formatted = false
                if case .saved(let f) = result { formatted = f }
                saved.append(EditorSavedFile(path: file, version: editor.documents[EditorModel.key(file, .own)]?.version ?? 0, formatted: formatted))
            } catch {
                failed.append(EditorSaveFailure(path: file, message: error.localizedDescription))
            }
        }
        return EditorSaveResult(saved: saved, failed: failed)
    }

    func openFile(path: String, line: Int?, col: Int?) async throws -> String {
        let file = try rel(path)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) else {
            throw EditorToolError(.notFound, "\(file) does not exist")
        }
        let span = line.map { SourceTarget.Span(line: $0, col: col ?? 1) }
        model.source = SourceTarget(file: file, origin: .own, primary: span)
        model.editorVisible = true
        do { try editor.show(file: file, origin: .own, span: span) } catch {
            throw EditorToolError(.notFound, "\(file) cannot be opened")
        }
        return file
    }
}

// MARK: - Logging

enum EditorMCPLog {
    nonisolated static let logger = Logger(subsystem: "io.github.synodlang.synod", category: "mcp")

    /// One line per call: kind, tool, path, byte counts, ok or error code, duration. Never text or tokens.
    nonisolated static func write(_ e: MCPCallLogEntry, kind: EditorMCPService.Kind) {
        logger.info("kind=\(kind.rawValue, privacy: .public) tool=\(e.tool, privacy: .public) path=\(e.path ?? "-", privacy: .public) in=\(e.bytesIn) out=\(e.bytesOut) result=\(e.errorCode ?? "ok", privacy: .public) ms=\(e.durationMs)")
    }
}

// MARK: - The listener and the tokens

/// The app's one editor listener and token table (decisions 98 to 100). The socket exists only while
/// a prompt-bar request runs or the external setting is on, and the external setting is never stored.
@MainActor @Observable
final class EditorMCPHub {
    static let shared = EditorMCPHub()

    /// What a prompt-bar request holds until its `claude` exits.
    struct Session {
        let token: String
        let config: MCPConfigFile
        let socket: URL
    }

    @ObservationIgnored let table = TokenTable()
    @ObservationIgnored let listener: UnixSocketListener
    @ObservationIgnored var windows: () -> [WorkspaceModel] = { WorkspaceRegistry.models }
    /// Receives every call's log entry as well as os_log (tests).
    @ObservationIgnored var logSink: (@Sendable (MCPCallLogEntry, String) -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The socket folder while any holder is active, so quitting can remove it.
    @ObservationIgnored private(set) var socketFolder: URL?

    private(set) var externalEnabled = false
    private(set) var externalToken: String?
    private(set) var externalSocket: URL?
    private(set) var externalConnections = 0
    private(set) var externalRoots: Set<String> = []
    private(set) var lastError: String?

    var appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    init(baseDirectory: URL? = nil) {
        listener = UnixSocketListener(authority: table, baseDirectory: baseDirectory)
    }

    // MARK: Registry

    func registry(model: WorkspaceModel, kind: EditorMCPService.Kind) -> EditorToolRegistry {
        let sink = logSink
        return EditorToolRegistry(service: EditorMCPService(model: model, kind: kind)) { entry in
            EditorMCPLog.write(entry, kind: kind)
            sink?(entry, kind.rawValue)
        }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Prompt bar

    func beginRequest(for model: WorkspaceModel, synod: URL, bridge: URL) async throws -> Session {
        let token = try MCPTokens.generate()
        let socket = try await listener.acquire()
        do {
            await table.add(token: token, grant: BridgeGrant(tools: registry(model: model, kind: .promptBar), serverVersion: appVersion))
            guard let folder = await listener.folderURL else { throw CocoaError(.fileNoSuchFile) }
            socketFolder = folder
            let config = try MCPConfigFile.write(
                servers: MCPConfigFile.promptBarServers(bridge: bridge.path, socket: socket.path, token: token, synod: synod.path), in: folder)
            return Session(token: token, config: config, socket: socket)
        } catch {
            await table.revoke(token: token)
            await listener.release()
            await refreshFolder()
            throw error
        }
    }

    /// Deletes the config file, revokes the token, closes its connections and drops the hold.
    func endRequest(_ session: Session) async {
        session.config.remove()
        await table.revoke(token: session.token)
        await listener.closeConnections(token: session.token)
        await listener.release()
        await refreshFolder()
    }

    private func refreshFolder() async { socketFolder = await listener.folderURL }

    // MARK: External sessions

    func setExternal(_ on: Bool) async {
        if on == externalEnabled { return }
        if on {
            do {
                let token = try MCPTokens.generate()
                let socket = try await listener.acquire()
                externalToken = token
                externalSocket = socket
                externalEnabled = true
                lastError = nil
                await table.add(token: token) { [weak self] workspace in await self?.externalGrant(workspace: workspace) }
                await refreshFolder()
                startPolling()
            } catch {
                lastError = "Could not start the editor socket: \(error.localizedDescription)"
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
            if let token = externalToken {
                await table.revoke(token: token)
                await listener.closeConnections(token: token)
            }
            await listener.release()
            await refreshFolder()
            externalToken = nil
            externalSocket = nil
            externalEnabled = false
            externalConnections = 0
            externalRoots = []
        }
    }

    /// Closes the external connections and rotates the token (the old copied line stops working).
    func disconnectExternal() async {
        guard externalEnabled, let old = externalToken else { return }
        await table.revoke(token: old)
        await listener.closeConnections(token: old)
        guard let token = try? MCPTokens.generate() else { return }
        externalToken = token
        await table.add(token: token) { [weak self] workspace in await self?.externalGrant(workspace: workspace) }
        externalConnections = 0
        externalRoots = []
    }

    private func externalGrant(workspace: String?) -> BridgeGrant? {
        guard let workspace, let model = windows().first(where: { Self.samePath($0.workspace.root.path, workspace) }) else { return nil }
        externalRoots.insert(model.workspace.root.standardizedFileURL.resolvingSymlinksInPath().path)
        return BridgeGrant(tools: registry(model: model, kind: .external), serverVersion: appVersion)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let token = self.externalToken else { return }
                let n = await self.listener.connectionCount(token: token)
                if n != self.externalConnections { self.externalConnections = n }
                if n == 0, !self.externalRoots.isEmpty { self.externalRoots = [] }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Whether a Terminal session is connected to `model`'s window.
    func externalConnected(to model: WorkspaceModel) -> Bool {
        guard externalConnections > 0 else { return false }
        return externalRoots.contains(model.workspace.root.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// Quitting: the socket folder goes with the process.
    func terminate() {
        if let socketFolder { try? FileManager.default.removeItem(at: socketFolder) }
    }

    // MARK: Copy MCP config

    /// The one line Settings copies (addendum A2).
    static func addCommand(token: String, bridge: String, socket: String, workspace: String) -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
        }
        return "claude mcp add --scope local synod-editor -e SYNOD_EDITOR_TOKEN=\(token) -- \(q(bridge)) --socket \(q(socket)) --workspace \(q(workspace))"
    }

    /// The line for `model`'s window, or nil when external access is off or the bridge is missing.
    func copyableCommand(for model: WorkspaceModel) -> String? {
        guard externalEnabled, let token = externalToken, let socket = externalSocket, let bridge = HelperTools.editorBridge() else { return nil }
        return Self.addCommand(token: token, bridge: bridge.path, socket: socket.path, workspace: model.workspace.root.path)
    }
}
