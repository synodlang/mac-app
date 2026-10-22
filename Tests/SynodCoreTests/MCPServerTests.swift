import Foundation
import Testing

@testable import SynodCore

struct MCPCodecTests {
    @Test func decodesRequestNotificationResponse() {
        #expect(JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) == .success(.request(id: .number(1, raw: "1"), method: "ping", params: nil)))
        #expect(JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":"a","method":"x","params":{}}"#) == .success(.request(id: .string("a"), method: "x", params: .object([]))))
        #expect(JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .success(.notification(method: "notifications/initialized", params: nil)))
        #expect(JSONRPCCodec.decode(line: #"{"jsonrpc":"2.0","id":1,"result":{}}"#) == .success(.response(id: .number(1, raw: "1"))))
    }

    @Test func rejectsBadLines() {
        func code(_ s: String) -> Int? {
            if case .failure(let e) = JSONRPCCodec.decode(line: s) { return e.code }
            return nil
        }
        #expect(code("not json") == -32700)
        #expect(code("") == -32700)
        #expect(code("[1]") == -32600)
        #expect(code(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600)
        #expect(code(#"{"id":1,"method":"ping"}"#) == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":1,"method":5}"#) == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":1,"method":"x","params":3}"#) == -32600)
        #expect(code(#"{"jsonrpc":"2.0","id":true,"method":"x"}"#) == -32600)
        if case .failure(let e) = JSONRPCCodec.decode(line: #"{"id":7,"method":"ping"}"#) { #expect(e.id == .number(7, raw: "7")) }
    }

    @Test func encodesOneLineInKeyOrder() {
        let line = JSONRPCCodec.result(id: .string("x"), MCPJSON.obj(("b", .string("a\nb\"\u{1}é/")), ("a", MCPJSON.int(2))))
        #expect(line == #"{"jsonrpc":"2.0","id":"x","result":{"b":"a\nb\"\u0001é/","a":2}}"#)
        #expect(!line.contains("\n"))
        #expect(JSONRPCCodec.error(id: .null, code: -32700, message: "Parse error") == #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#)
    }
}

struct MCPServerTests {
    func server(_ editor: MockEditor = MockEditor()) -> MCPServer {
        MCPServer(name: "synod-editor", version: "9.9.9", tools: EditorToolRegistry(service: editor))
    }

    func ask(_ s: MCPServer, _ line: String) async throws -> JSONValue {
        let out = try #require(await s.handle(line: line))
        #expect(!out.contains("\n"))
        return try JSONParser.parse(out)
    }

    @Test func versionTable() async throws {
        for v in ["2025-11-25", "2025-06-18", "2025-03-26"] {
            let r = try await ask(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(v)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
            #expect(r["result"]?["protocolVersion"]?.stringValue == v)
        }
        for v in ["2024-11-05", "1999", "2026-01-01"] {
            let r = try await ask(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(v)"}}"#)
            #expect(r["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        }
        let r = try await ask(server(), #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(MCPJSON.encode(r["result"]!["capabilities"]!) == #"{"tools":{"listChanged":false}}"#)
        #expect(MCPJSON.encode(r["result"]!["serverInfo"]!) == #"{"name":"synod-editor","version":"9.9.9"}"#)
        let bad = try await ask(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        #expect(bad["error"]?["code"]?.int64Value == -32602)
    }

    @Test func methodSet() async throws {
        let s = server()
        #expect(try await ask(s, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)["result"] == .object([]))
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#) == nil)
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/other"}"#) == nil)
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","id":4,"result":{}}"#) == nil)
        for m in ["resources/list", "resources/read", "prompts/list", "prompts/get", "sampling/createMessage", "logging/setLevel", "completion/complete", "roots/list", "elicitation/create", "tools/nope"] {
            let r = try await ask(s, #"{"jsonrpc":"2.0","id":1,"method":"\#(m)"}"#)
            #expect(r["error"]?["code"]?.int64Value == -32601, "\(m)")
        }
        #expect(try await ask(s, "garbage")["error"]?["code"]?.int64Value == -32700)
        #expect(try await ask(s, "garbage")["id"] == .null)
        #expect(try await ask(s, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)["error"]?["code"]?.int64Value == -32600)
    }

    @Test func toolsListEqualsGolden() async throws {
        let r = try await ask(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let golden = try JSONParser.parse(try Fixtures.data("mcp/tools.json"))
        #expect(r["result"] == golden)
        #expect(r["result"]?["nextCursor"] == nil)
        let names = golden["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["list_files", "read_buffer", "get_diagnostics", "get_selection", "apply_edits", "replace_buffer", "create_file", "save_files", "open_file"])
    }

    @Test func callsReturnStructuredAndText() async throws {
        let editor = MockEditor()
        let s = server(editor)
        let r = try await ask(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_files","arguments":{}}}"#)
        let result = try #require(r["result"])
        #expect(result["isError"] == nil)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONParser.parse(text) == result["structuredContent"])
        #expect(text == #"{"files":[{"path":"a.synod","open":true,"dirty":true,"readOnly":false,"version":3}]}"#)
        // fresh defaults to true
        _ = try await ask(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_diagnostics"}}"#)
        #expect(await editor.calls.last == "get_diagnostics fresh=true")
        _ = try await ask(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_diagnostics","arguments":{"fresh":false}}}"#)
        #expect(await editor.calls.last == "get_diagnostics fresh=false")
    }

    @Test func errorCodesAreToolFailures() async throws {
        let s = server()
        func fail(_ call: String) async throws -> String? {
            let r = try await ask(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(call)}"#)
            #expect(r["result"]?["isError"] == .bool(true), "\(call)")
            return r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        #expect(try await fail(#"{"name":"read_buffer","arguments":{"path":"../x"}}"#)?.hasPrefix("outside-module: ") == true)
        #expect(try await fail(#"{"name":"read_buffer","arguments":{"path":"missing.synod"}}"#)?.hasPrefix("not-found: ") == true)
        #expect(try await fail(#"{"name":"apply_edits","arguments":{"path":"a.synod","version":1,"edits":[{"line":1,"col":1,"endLine":1,"endCol":1,"text":""}]}}"#) == "version-mismatch: buffer is at version 3; read it again")
        #expect(try await fail(#"{"name":"replace_buffer","arguments":{"path":"a.synod","version":3,"text":""}}"#) == "read-only: bundled examples; copy them to a folder first")
        #expect(try await fail(#"{"name":"read_buffer","arguments":{"path":"a.synod","startLine":5,"endLine":2}}"#)?.hasPrefix("bad-arguments: ") == true)
        #expect(EditorErrorCode.allCases.map(\.rawValue) == ["not-found", "outside-module", "read-only", "version-mismatch", "bad-range", "exists", "too-large", "busy", "bad-arguments"])
    }

    @Test func protocolErrorsForUnknownToolAndSchemaViolations() async throws {
        let s = server()
        for call in [
            #"{"name":"nope","arguments":{}}"#, #"{"arguments":{}}"#, #"{"name":"read_buffer","arguments":{}}"#,
            #"{"name":"read_buffer","arguments":{"path":"a","extra":1}}"#, #"{"name":"read_buffer","arguments":{"path":"a","startLine":0}}"#,
            #"{"name":"read_buffer","arguments":{"path":3}}"#, #"{"name":"apply_edits","arguments":{"path":"a","version":1,"edits":[]}}"#,
            #"{"name":"create_file","arguments":{"path":"a.txt","text":""}}"#, #"{"name":"save_files","arguments":{"paths":[]}}"#,
            #"{"name":"read_buffer","arguments":{"path":"a","startLine":1.5}}"#,
        ] {
            let r = try await ask(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(call)}"#)
            #expect(r["error"]?["code"]?.int64Value == -32602, "\(call)")
        }
    }

    @Test func cancelledNotificationCancelsAndSuppressesTheResponse() async throws {
        let editor = MockEditor()
        await editor.setWaitForCancel(true)
        let s = server(editor)
        async let pending = s.handle(line: #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"get_diagnostics","arguments":{}}}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}"#) == nil)
        #expect(await pending == nil)
        #expect(await editor.sawCancellation)
    }

    @Test func logEntriesCarryNoText() async throws {
        let box = LockedBox<[MCPCallLogEntry]>([])
        let s = MCPServer(name: "x", version: "1", tools: EditorToolRegistry(service: MockEditor(), log: { e in box.mutate { $0.append(e) } }))
        _ = await s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"replace_buffer","arguments":{"path":"a.synod","version":3,"text":"SECRET TEXT"}}}"#)
        let entry = try #require(box.value.first)
        #expect(entry.tool == "replace_buffer" && entry.path == "a.synod" && entry.errorCode == "read-only")
        #expect(!"\(entry)".contains("SECRET"))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&stored); lock.unlock() }
}
