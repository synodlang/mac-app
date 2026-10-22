import Foundation

/// The published definitions of the editor tools (decision 99), parsed once from JSON text so key order is kept.
enum EditorToolSchemas {
    private static func parse(_ s: String) -> JSONValue {
        do { return try JSONParser.parse(s) } catch { fatalError("bad built-in schema: \(error)") }
    }

    private static let emptyInput = #"{"type":"object","properties":{},"additionalProperties":false}"#
    private static let editResult = #"{"type":"object","required":["path","version","dirty"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer"},"dirty":{"type":"boolean"}}}"#
    private static let readOnly = #"{"readOnlyHint":true}"#
    private static let writes = #"{"readOnlyHint":false,"destructiveHint":false}"#

    private static func tool(_ name: String, _ description: String, input: String, output: String, annotations: String) -> MCPTool {
        MCPTool(name: name, description: description, inputSchema: parse(input), outputSchema: parse(output), annotations: parse(annotations))
    }

    static let all: [MCPTool] = [
        tool(
            "list_files", "List the module's Synod files with their editor state.",
            input: emptyInput,
            output: #"{"type":"object","required":["files"],"additionalProperties":false,"properties":{"files":{"type":"array","items":{"type":"object","required":["path","open","dirty","readOnly","version"],"additionalProperties":false,"properties":{"path":{"type":"string"},"open":{"type":"boolean"},"dirty":{"type":"boolean"},"readOnly":{"type":"boolean"},"version":{"type":"integer"}}}}}}"#,
            annotations: readOnly),
        tool(
            "read_buffer", "Read a file as the editor holds it, unsaved changes included.",
            input: #"{"type":"object","required":["path"],"additionalProperties":false,"properties":{"path":{"type":"string"},"startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1}}}"#,
            output: #"{"type":"object","required":["path","version","dirty","readOnly","lineCount","startLine","endLine","text"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer"},"dirty":{"type":"boolean"},"readOnly":{"type":"boolean"},"lineCount":{"type":"integer"},"startLine":{"type":"integer"},"endLine":{"type":"integer"},"text":{"type":"string"}}}"#,
            annotations: readOnly),
        tool(
            "get_diagnostics", "Diagnostics of the module including unsaved buffers; fresh runs a check now.",
            input: #"{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"fresh":{"type":"boolean","default":true}}}"#,
            output: #"{"type":"object","required":["stale","diagnostics"],"additionalProperties":false,"properties":{"stale":{"type":"boolean"},"diagnostics":{"type":"array","items":{"type":"object","required":["path","line","col","endLine","endCol","severity","code","message","hint"],"additionalProperties":false,"properties":{"path":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"},"endLine":{"type":"integer"},"endCol":{"type":"integer"},"severity":{"type":"string"},"code":{"type":"string"},"message":{"type":"string"},"hint":{"type":["string","null"]}}}}}}"#,
            annotations: readOnly),
        tool(
            "get_selection", "The file, caret and selections the user has in the editor.",
            input: emptyInput,
            output: #"{"type":"object","required":["path","version","caret","selections"],"additionalProperties":false,"properties":{"path":{"type":["string","null"]},"version":{"type":["integer","null"]},"caret":{"type":["object","null"],"required":["line","col"],"additionalProperties":false,"properties":{"line":{"type":"integer"},"col":{"type":"integer"}}},"selections":{"type":"array","items":{"type":"object","required":["line","col","endLine","endCol","text"],"additionalProperties":false,"properties":{"line":{"type":"integer"},"col":{"type":"integer"},"endLine":{"type":"integer"},"endCol":{"type":"integer"},"text":{"type":"string"}}}}}}"#,
            annotations: readOnly),
        tool(
            "apply_edits", "Apply non-overlapping edits to one buffer as one undoable change; the file stays unsaved.",
            input: #"{"type":"object","required":["path","version","edits"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer","minimum":0},"edits":{"type":"array","minItems":1,"maxItems":1000,"items":{"type":"object","required":["line","col","endLine","endCol","text"],"additionalProperties":false,"properties":{"line":{"type":"integer","minimum":1},"col":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1},"endCol":{"type":"integer","minimum":1},"text":{"type":"string"}}}}}}"#,
            output: editResult, annotations: writes),
        tool(
            "replace_buffer", "Replace a buffer's whole text as one undoable change; the file stays unsaved.",
            input: #"{"type":"object","required":["path","version","text"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer","minimum":0},"text":{"type":"string","maxLength":1048576}}}"#,
            output: editResult, annotations: writes),
        tool(
            "create_file", "Create a new .synod file on disk with this text, formatted, and open it.",
            input: #"{"type":"object","required":["path","text"],"additionalProperties":false,"properties":{"path":{"type":"string","pattern":"\\.synod$"},"text":{"type":"string","maxLength":1048576}}}"#,
            output: #"{"type":"object","required":["path","version","formatted"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer"},"formatted":{"type":"boolean"}}}"#,
            annotations: writes),
        tool(
            "save_files", "Save buffers exactly as the user's Save does (atomic write, then synod fmt).",
            input: #"{"type":"object","required":["paths"],"additionalProperties":false,"properties":{"paths":{"type":"array","minItems":1,"items":{"type":"string"}}}}"#,
            output: #"{"type":"object","required":["saved","failed"],"additionalProperties":false,"properties":{"saved":{"type":"array","items":{"type":"object","required":["path","version","formatted"],"additionalProperties":false,"properties":{"path":{"type":"string"},"version":{"type":"integer"},"formatted":{"type":"boolean"}}}},"failed":{"type":"array","items":{"type":"object","required":["path","message"],"additionalProperties":false,"properties":{"path":{"type":"string"},"message":{"type":"string"}}}}}}"#,
            annotations: writes),
        tool(
            "open_file", "Show a file in the editor, optionally at a position.",
            input: #"{"type":"object","required":["path"],"additionalProperties":false,"properties":{"path":{"type":"string"},"line":{"type":"integer","minimum":1},"col":{"type":"integer","minimum":1}}}"#,
            output: #"{"type":"object","required":["path"],"additionalProperties":false,"properties":{"path":{"type":"string"}}}"#,
            annotations: readOnly),
    ]
}
