import Foundation

/// JSON-RPC 2.0 error codes used by the MCP servers.
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

/// A decoded incoming JSON-RPC message.
public enum JSONRPCIncoming: Equatable, Sendable {
    /// A request with an id (a number or a string).
    case request(id: JSONValue, method: String, params: JSONValue?)
    /// A message with no id.
    case notification(method: String, params: JSONValue?)
    /// A response from the peer (a result or an error); servers ignore these.
    case response(id: JSONValue)
}

/// A failure while decoding a line, with the id to answer to (null when unknown).
public struct JSONRPCDecodeError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let id: JSONValue
}

/// Decoding and encoding of one JSON-RPC 2.0 message per line.
public enum JSONRPCCodec {
    public static func decode(line: String) -> Result<JSONRPCIncoming, JSONRPCDecodeError> {
        let root: JSONValue
        do {
            root = try JSONParser.parse(line)
        } catch {
            return .failure(JSONRPCDecodeError(code: JSONRPCErrorCode.parseError, message: "Parse error", id: .null))
        }
        guard case .object = root else {
            return .failure(
                JSONRPCDecodeError(code: JSONRPCErrorCode.invalidRequest, message: "Invalid request: batches and non-objects are not supported", id: .null))
        }
        let rawID = root["id"]
        let validID: JSONValue? = {
            switch rawID {
            case .some(.string), .some(.number): return rawID
            default: return nil
            }
        }()
        func invalid(_ why: String) -> Result<JSONRPCIncoming, JSONRPCDecodeError> {
            .failure(JSONRPCDecodeError(code: JSONRPCErrorCode.invalidRequest, message: "Invalid request: \(why)", id: validID ?? .null))
        }
        guard root["jsonrpc"]?.stringValue == "2.0" else { return invalid("jsonrpc must be \"2.0\"") }
        if let rawID, validID == nil, !(rawID.isNull && root["method"] == nil) {
            return invalid("id must be a string or a number")
        }
        guard let methodValue = root["method"] else {
            if let validID, root["result"] != nil || root["error"] != nil { return .success(.response(id: validID)) }
            return invalid("method is missing")
        }
        guard let method = methodValue.stringValue else { return invalid("method must be a string") }
        let params = root["params"]
        if let params {
            switch params {
            case .object, .array: break
            default: return invalid("params must be an object or an array")
            }
        }
        if let validID { return .success(.request(id: validID, method: method, params: params)) }
        return .success(.notification(method: method, params: params))
    }

    public static func result(id: JSONValue, _ result: JSONValue) -> String {
        MCPJSON.encode(MCPJSON.obj(("jsonrpc", .string("2.0")), ("id", id), ("result", result)))
    }

    public static func error(id: JSONValue, code: Int, message: String) -> String {
        let err = MCPJSON.obj(("code", MCPJSON.int(code)), ("message", .string(message)))
        return MCPJSON.encode(MCPJSON.obj(("jsonrpc", .string("2.0")), ("id", id), ("error", err)))
    }

    public static func request(id: Int, method: String, params: JSONValue? = nil) -> String {
        var pairs: [(String, JSONValue)] = [("jsonrpc", .string("2.0")), ("id", MCPJSON.int(id)), ("method", .string(method))]
        if let params { pairs.append(("params", params)) }
        return MCPJSON.encode(.object(pairs.map { JSONMember(key: $0.0, value: $0.1) }))
    }
}
