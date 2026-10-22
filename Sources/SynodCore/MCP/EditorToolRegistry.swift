import Foundation

/// What a tool call leaves in a log: never text, edit contents or tokens.
public struct MCPCallLogEntry: Sendable, Equatable {
    public let tool: String
    public let path: String?
    public let bytesIn: Int
    public let bytesOut: Int
    /// The `EditorErrorCode` raw value, "error" or "cancelled" on failure; nil on success.
    public let errorCode: String?
    public let durationMs: Int
}

/// The editor tools (server `synod-editor`), dispatching to an `EditorService`.
public struct EditorToolRegistry: ToolProvider {
    public let service: any EditorService
    private let log: (@Sendable (MCPCallLogEntry) -> Void)?

    public init(service: any EditorService, log: (@Sendable (MCPCallLogEntry) -> Void)? = nil) {
        self.service = service
        self.log = log
    }

    public var tools: [MCPTool] { EditorToolSchemas.all }

    public func call(name: String, arguments: JSONValue) async -> ToolCallResult {
        let start = ContinuousClock.now
        let result: ToolCallResult
        var code: String?
        do {
            result = .success(try await dispatch(name, arguments))
        } catch let e as EditorToolError {
            code = e.code.rawValue
            result = .failure(e.description)
        } catch is CancellationError {
            code = "cancelled"
            result = .failure("cancelled")
        } catch {
            code = "error"
            result = .failure("error: \(error.localizedDescription)")
        }
        if let log {
            let d = ContinuousClock.now - start
            let ms = Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
            var path = arguments["path"]?.stringValue
            if path == nil, let paths = arguments["paths"]?.arrayValue { path = paths.compactMap(\.stringValue).joined(separator: ",") }
            log(
                MCPCallLogEntry(
                    tool: name, path: path, bytesIn: MCPJSON.encode(arguments).utf8.count, bytesOut: result.text.utf8.count,
                    errorCode: code, durationMs: ms))
        }
        return result
    }

    // MARK: Dispatch

    private func dispatch(_ name: String, _ a: JSONValue) async throws -> JSONValue {
        switch name {
        case "list_files":
            let files = try await service.listFiles()
            return MCPJSON.obj(
                ("files", .array(files.map {
                    MCPJSON.obj(("path", .string($0.path)), ("open", .bool($0.open)), ("dirty", .bool($0.dirty)), ("readOnly", .bool($0.readOnly)), ("version", MCPJSON.int($0.version)))
                })))
        case "read_buffer":
            let start = a["startLine"].flatMap(int), end = a["endLine"].flatMap(int)
            if let start, let end, end < start { throw EditorToolError(.badArguments, "endLine is before startLine") }
            let r = try await service.readBuffer(path: try path(a), startLine: start, endLine: end)
            return MCPJSON.obj(
                ("path", .string(r.path)), ("version", MCPJSON.int(r.version)), ("dirty", .bool(r.dirty)), ("readOnly", .bool(r.readOnly)),
                ("lineCount", MCPJSON.int(r.lineCount)), ("startLine", MCPJSON.int(r.startLine)), ("endLine", MCPJSON.int(r.endLine)), ("text", .string(r.text)))
        case "get_diagnostics":
            var fresh = true
            if case .bool(let b)? = a["fresh"] { fresh = b }
            let r = try await service.diagnostics(path: a["path"]?.stringValue, fresh: fresh)
            return MCPJSON.obj(
                ("stale", .bool(r.stale)),
                ("diagnostics", .array(r.diagnostics.map {
                    MCPJSON.obj(
                        ("path", .string($0.path)), ("line", MCPJSON.int($0.line)), ("col", MCPJSON.int($0.col)), ("endLine", MCPJSON.int($0.endLine)),
                        ("endCol", MCPJSON.int($0.endCol)), ("severity", .string($0.severity)), ("code", .string($0.code)), ("message", .string($0.message)),
                        ("hint", MCPJSON.optStr($0.hint)))
                })))
        case "get_selection":
            let r = try await service.selection()
            return MCPJSON.obj(
                ("path", MCPJSON.optStr(r.path)), ("version", MCPJSON.optInt(r.version)),
                ("caret", r.caret.map { MCPJSON.obj(("line", MCPJSON.int($0.line)), ("col", MCPJSON.int($0.col))) } ?? .null),
                ("selections", .array(r.selections.map {
                    MCPJSON.obj(("line", MCPJSON.int($0.line)), ("col", MCPJSON.int($0.col)), ("endLine", MCPJSON.int($0.endLine)), ("endCol", MCPJSON.int($0.endCol)), ("text", .string($0.text)))
                })))
        case "apply_edits":
            let edits: [EditorTextEdit] = (a["edits"]?.arrayValue ?? []).compactMap { e in
                guard let l = e["line"].flatMap(int), let c = e["col"].flatMap(int), let el = e["endLine"].flatMap(int), let ec = e["endCol"].flatMap(int),
                    let t = e["text"]?.stringValue
                else { return nil }
                return EditorTextEdit(line: l, col: c, endLine: el, endCol: ec, text: t)
            }
            guard edits.count == (a["edits"]?.arrayValue?.count ?? 0) else { throw EditorToolError(.badArguments, "malformed edit") }
            let total = edits.reduce(0) { $0 + $1.text.utf8.count }
            if total > 1_048_576 { throw EditorToolError(.tooLarge, "edits add more than 1 MB of text") }
            return editJSON(try await service.applyEdits(path: try path(a), version: try version(a), edits: edits))
        case "replace_buffer":
            guard let text = a["text"]?.stringValue else { throw EditorToolError(.badArguments, "text is required") }
            if text.utf8.count > 1_048_576 { throw EditorToolError(.tooLarge, "text is larger than 1 MB") }
            return editJSON(try await service.replaceBuffer(path: try path(a), version: try version(a), text: text))
        case "create_file":
            guard let text = a["text"]?.stringValue else { throw EditorToolError(.badArguments, "text is required") }
            if text.utf8.count > 1_048_576 { throw EditorToolError(.tooLarge, "text is larger than 1 MB") }
            let r = try await service.createFile(path: try path(a), text: text)
            return MCPJSON.obj(("path", .string(r.path)), ("version", MCPJSON.int(r.version)), ("formatted", .bool(r.formatted)))
        case "save_files":
            let paths = (a["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
            let r = try await service.saveFiles(paths: paths)
            return MCPJSON.obj(
                ("saved", .array(r.saved.map { MCPJSON.obj(("path", .string($0.path)), ("version", MCPJSON.int($0.version)), ("formatted", .bool($0.formatted))) })),
                ("failed", .array(r.failed.map { MCPJSON.obj(("path", .string($0.path)), ("message", .string($0.message))) })))
        case "open_file":
            let p = try await service.openFile(path: try path(a), line: a["line"].flatMap(int), col: a["col"].flatMap(int))
            return MCPJSON.obj(("path", .string(p)))
        default:
            throw EditorToolError(.badArguments, "unknown tool \(name)")
        }
    }

    private func editJSON(_ r: EditorEditResult) -> JSONValue {
        MCPJSON.obj(("path", .string(r.path)), ("version", MCPJSON.int(r.version)), ("dirty", .bool(r.dirty)))
    }

    private func int(_ v: JSONValue) -> Int? { v.int64Value.map(Int.init) }

    private func path(_ a: JSONValue) throws -> String {
        guard let p = a["path"]?.stringValue else { throw EditorToolError(.badArguments, "path is required") }
        return p
    }

    private func version(_ a: JSONValue) throws -> Int {
        guard let v = a["version"].flatMap(int) else { throw EditorToolError(.badArguments, "version is required") }
        return v
    }
}
