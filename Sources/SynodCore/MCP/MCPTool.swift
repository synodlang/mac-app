import Foundation

/// A tool as `tools/list` publishes it.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let annotations: JSONValue?

    public init(name: String, description: String, inputSchema: JSONValue, outputSchema: JSONValue? = nil, annotations: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    /// The `tools/list` entry (key order: name, description, inputSchema, outputSchema, annotations).
    public var json: JSONValue {
        var pairs: [(String, JSONValue)] = [("name", .string(name)), ("description", .string(description)), ("inputSchema", inputSchema)]
        if let outputSchema { pairs.append(("outputSchema", outputSchema)) }
        if let annotations { pairs.append(("annotations", annotations)) }
        return .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
    }
}

/// The outcome of a tool call.
public struct ToolCallResult: Sendable, Equatable {
    public var structuredContent: JSONValue?
    public var text: String
    public var isError: Bool

    public init(structuredContent: JSONValue? = nil, text: String, isError: Bool = false) {
        self.structuredContent = structuredContent
        self.text = text
        self.isError = isError
    }

    /// A success carrying `value` as structured content and the same JSON as text.
    public static func success(_ value: JSONValue) -> ToolCallResult {
        ToolCallResult(structuredContent: value, text: MCPJSON.encode(value))
    }

    public static func failure(_ text: String) -> ToolCallResult { ToolCallResult(text: text, isError: true) }

    var json: JSONValue {
        var pairs: [(String, JSONValue)] = [("content", .array([MCPJSON.obj(("type", .string("text")), ("text", .string(text)))]))]
        if let structuredContent { pairs.append(("structuredContent", structuredContent)) }
        if isError { pairs.append(("isError", .bool(true))) }
        return .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
    }
}

/// Something that lists tools and runs them. `MCPServer` validates arguments against `inputSchema` before `call`.
public protocol ToolProvider: Sendable {
    var tools: [MCPTool] { get }
    func call(name: String, arguments: JSONValue) async -> ToolCallResult
}

/// A validator for the JSON Schema subset the tool schemas use: type, properties, required,
/// additionalProperties:false, minimum, maxLength, pattern, minItems, maxItems, items.
enum SchemaValidator {
    /// The first violation as text, or nil when `value` fits `schema`.
    static func validate(_ value: JSONValue, against schema: JSONValue, at path: String = "arguments") -> String? {
        if let type = schema["type"] {
            let allowed = type.stringValue.map { [$0] } ?? (type.arrayValue ?? []).compactMap(\.stringValue)
            if !allowed.contains(where: { matches(value, type: $0) }) {
                return "\(path) must be \(allowed.joined(separator: " or "))"
            }
        }
        switch value {
        case .object(let members):
            let props = schema["properties"]
            for req in schema["required"]?.arrayValue ?? [] {
                if let name = req.stringValue, value[name] == nil { return "\(path).\(name) is required" }
            }
            for m in members {
                if let sub = props?[m.key] {
                    if let e = validate(m.value, against: sub, at: "\(path).\(m.key)") { return e }
                } else if case .bool(false)? = schema["additionalProperties"] {
                    return "\(path).\(m.key) is not allowed"
                }
            }
        case .array(let items):
            if let n = schema["minItems"]?.int64Value, items.count < Int(n) { return "\(path) needs at least \(n) items" }
            if let n = schema["maxItems"]?.int64Value, items.count > Int(n) { return "\(path) allows at most \(n) items" }
            if let sub = schema["items"] {
                for (i, item) in items.enumerated() {
                    if let e = validate(item, against: sub, at: "\(path)[\(i)]") { return e }
                }
            }
        case .number(let d, _):
            if let min = schema["minimum"]?.doubleValue, d < min { return "\(path) must be at least \(schema["minimum"]?.int64Value.map(String.init) ?? String(min))" }
        case .string(let s):
            if let n = schema["maxLength"]?.int64Value, s.unicodeScalars.count > Int(n) { return "\(path) is longer than \(n) characters" }
            if let pattern = schema["pattern"]?.stringValue,
                s.range(of: pattern, options: .regularExpression) == nil
            {
                return "\(path) does not match \(pattern)"
            }
        default: break
        }
        return nil
    }

    private static func matches(_ v: JSONValue, type: String) -> Bool {
        switch (type, v) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): return true
        case ("integer", .number): return v.int64Value != nil
        default: return false
        }
    }
}
