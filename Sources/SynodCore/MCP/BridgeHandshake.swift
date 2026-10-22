import Foundation
import Security

/// The first line a bridge sends on the socket, and the token helpers around it.
public struct BridgeHandshake: Equatable, Sendable {
    public static let version = 1
    /// The line the app answers on success; on refusal it just closes the connection.
    public static let okLine = #"{"ok":true}"#
    /// The one stderr line the bridge prints when refused or when the socket is missing.
    public static let refusalMessage = "synod-editor-mcp: Synod is not accepting editor connections"

    public var token: String
    public var workspace: String?

    public init(token: String, workspace: String?) {
        self.token = token
        self.workspace = workspace
    }

    /// `{"synodEditorBridge":1,"token":"<64 hex>","workspace":"<abs path or null>"}` without a newline.
    public var line: String {
        MCPJSON.encode(MCPJSON.obj(("synodEditorBridge", MCPJSON.int(Self.version)), ("token", .string(token)), ("workspace", MCPJSON.optStr(workspace))))
    }

    public static func parse(line: String) -> BridgeHandshake? {
        guard let v = try? JSONParser.parse(line), v["synodEditorBridge"]?.int64Value == Int64(version),
            let token = v["token"]?.stringValue, isValidToken(token)
        else { return nil }
        let ws = v["workspace"]
        if let ws, !ws.isNull, ws.stringValue == nil { return nil }
        return BridgeHandshake(token: token, workspace: ws?.stringValue)
    }

    /// 64 lowercase or uppercase hex digits.
    public static func isValidToken(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// Compares without stopping at the first difference; time depends only on the longer length.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff: UInt8 = x.count == y.count ? 0 : 1
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}

public enum MCPTokens {
    public struct RandomFailure: Error { public let status: Int32 }

    /// 32 random bytes from `SecRandomCopyBytes`, as 64 lowercase hex digits.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw RandomFailure(status: status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// What a valid token opens: the tools of one editor window and how to label the session.
public struct BridgeGrant: Sendable {
    public let tools: any ToolProvider
    public let serverName: String
    public let serverVersion: String
    public init(tools: any ToolProvider, serverName: String = "synod-editor", serverVersion: String) {
        self.tools = tools
        self.serverName = serverName
        self.serverVersion = serverVersion
    }
}

/// Decides whether a handshake is accepted.
public protocol BridgeAuthority: Sendable {
    func authorize(_ handshake: BridgeHandshake) async -> BridgeGrant?
}

/// A table of live tokens. Lookups compare against every token in constant time.
public actor TokenTable: BridgeAuthority {
    public typealias Resolver = @Sendable (_ workspace: String?) async -> BridgeGrant?
    private var entries: [(token: String, resolve: Resolver)] = []

    public init() {}

    /// Registers `token`. The resolver gets the handshake's workspace (nil for none) and returns the grant, or nil to refuse.
    public func add(token: String, resolve: @escaping Resolver) {
        entries.removeAll { $0.token == token }
        entries.append((token, resolve))
    }

    /// A token bound to one grant whatever the workspace (the prompt bar).
    public func add(token: String, grant: BridgeGrant) { add(token: token) { _ in grant } }

    public func revoke(token: String) { entries.removeAll { $0.token == token } }
    public func revokeAll() { entries.removeAll() }
    public var count: Int { entries.count }

    public func authorize(_ handshake: BridgeHandshake) async -> BridgeGrant? {
        var match: Resolver?
        for e in entries where BridgeHandshake.constantTimeEquals(e.token, handshake.token) { match = e.resolve }
        guard let match else { return nil }
        return await match(handshake.workspace)
    }
}
