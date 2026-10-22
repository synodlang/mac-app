import Foundation

/// A Model Context Protocol server working on lines: one JSON-RPC message in, at most one line out.
/// It knows only `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call` and
/// `notifications/cancelled`; every other method is -32601.
public actor MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let fallbackProtocolVersion = "2025-11-25"

    public let name: String
    public let version: String
    private let provider: any ToolProvider
    private var inflight: [String: Task<ToolCallResult, Never>] = [:]
    private var cancelled: Set<String> = []
    /// The protocol version answered to `initialize` (nil before).
    public private(set) var negotiatedVersion: String?

    public init(name: String, version: String, tools: any ToolProvider) {
        self.name = name
        self.version = version
        self.provider = tools
    }

    /// Handles one line; returns the response line (without newline) or nil when none is due.
    /// The caller may run several `handle` calls concurrently (a `tools/call` can wait).
    public func handle(line: String) async -> String? {
        switch JSONRPCCodec.decode(line: line) {
        case .failure(let e):
            return JSONRPCCodec.error(id: e.id, code: e.code, message: e.message)
        case .success(.response):
            return nil
        case .success(.notification(let method, let params)):
            if method == "notifications/cancelled", let rid = params?["requestId"] {
                let key = MCPJSON.encode(rid)
                if let task = inflight[key] {
                    cancelled.insert(key)
                    task.cancel()
                }
            }
            return nil
        case .success(.request(let id, let method, let params)):
            return await request(id: id, method: method, params: params)
        }
    }

    /// Cancels every running call (the connection closed).
    public func cancelAll() {
        for (key, task) in inflight {
            cancelled.insert(key)
            task.cancel()
        }
    }

    private func request(id: JSONValue, method: String, params: JSONValue?) async -> String? {
        switch method {
        case "initialize":
            guard let requested = params?["protocolVersion"]?.stringValue else {
                return JSONRPCCodec.error(id: id, code: JSONRPCErrorCode.invalidParams, message: "protocolVersion is required")
            }
            let chosen = Self.supportedProtocolVersions.contains(requested) ? requested : Self.fallbackProtocolVersion
            negotiatedVersion = chosen
            let result = MCPJSON.obj(
                ("protocolVersion", .string(chosen)),
                ("capabilities", MCPJSON.obj(("tools", MCPJSON.obj(("listChanged", .bool(false)))))),
                ("serverInfo", MCPJSON.obj(("name", .string(name)), ("version", .string(version)))))
            return JSONRPCCodec.result(id: id, result)
        case "ping":
            return JSONRPCCodec.result(id: id, .object([]))
        case "tools/list":
            return JSONRPCCodec.result(id: id, MCPJSON.obj(("tools", .array(provider.tools.map(\.json)))))
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return JSONRPCCodec.error(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func callTool(id: JSONValue, params: JSONValue?) async -> String? {
        func invalid(_ m: String) -> String { JSONRPCCodec.error(id: id, code: JSONRPCErrorCode.invalidParams, message: m) }
        guard let toolName = params?["name"]?.stringValue else { return invalid("name is required") }
        guard let tool = provider.tools.first(where: { $0.name == toolName }) else { return invalid("Unknown tool: \(toolName)") }
        var arguments = params?["arguments"] ?? .object([])
        if arguments.isNull { arguments = .object([]) }
        if let problem = SchemaValidator.validate(arguments, against: tool.inputSchema) { return invalid("Invalid arguments: \(problem)") }

        let key = MCPJSON.encode(id)
        let provider = self.provider
        let args = arguments
        let task = Task { await provider.call(name: toolName, arguments: args) }
        inflight[key] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inflight[key] = nil
        if cancelled.remove(key) != nil { return nil }
        return JSONRPCCodec.result(id: id, result.json)
    }
}
