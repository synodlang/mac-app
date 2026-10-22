import Foundation

/// One entry of `mcpServers` in a Claude Code `--mcp-config` file.
public struct MCPServerEntry: Sendable, Equatable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [(key: String, value: String)]

    public init(name: String, command: String, args: [String], env: [(key: String, value: String)] = []) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    public static func == (a: MCPServerEntry, b: MCPServerEntry) -> Bool {
        a.name == b.name && a.command == b.command && a.args == b.args && a.env.map(\.key) == b.env.map(\.key) && a.env.map(\.value) == b.env.map(\.value)
    }
}

/// A Claude Code MCP config file, created 0600 and removed when the request ends.
public struct MCPConfigFile: Sendable {
    public let url: URL

    /// The JSON text for `servers` (type stdio).
    public static func json(servers: [MCPServerEntry]) -> String {
        let members = servers.map { s in
            JSONMember(
                key: s.name,
                value: MCPJSON.obj(
                    ("type", .string("stdio")), ("command", .string(s.command)), ("args", .array(s.args.map { .string($0) })),
                    ("env", .object(s.env.map { JSONMember(key: $0.key, value: .string($0.value)) }))))
        }
        return MCPJSON.encode(MCPJSON.obj(("mcpServers", .object(members)))) + "\n"
    }

    /// The prompt-bar config: the editor bridge (token in `env`, never argv) and `synod mcp`.
    public static func promptBarServers(bridge: String, socket: String, token: String, synod: String) -> [MCPServerEntry] {
        [
            MCPServerEntry(name: "synod-editor", command: bridge, args: ["--socket", socket], env: [("SYNOD_EDITOR_TOKEN", token)]),
            MCPServerEntry(name: "synod", command: synod, args: ["mcp"], env: []),
        ]
    }

    /// Writes `claude-<random>.json` into `folder` with mode 0600 (created exclusively with that mode).
    public static func write(servers: [MCPServerEntry], in folder: URL) throws -> MCPConfigFile {
        let suffix = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let url = folder.appendingPathComponent("claude-\(suffix).json")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let bytes = Array(json(servers: servers).utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                unlink(url.path)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            off += n
        }
        return MCPConfigFile(url: url)
    }

    /// Deletes the file; safe to call twice.
    public func remove() { unlink(url.path) }
}
