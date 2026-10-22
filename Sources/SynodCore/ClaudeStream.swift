import Foundation

public enum ClaudeEvent: Sendable, Equatable {
    case initialized(sessionID: String, model: String?)
    case text(String)
    case toolUse(id: String?, name: String, inputSummary: String)
    case toolResult(toolUseID: String?, isError: Bool)
    case result(isError: Bool, text: String, sessionID: String?, durationMs: Int?)
    case other

    /// The progress line for a tool use ("Read twopc/twopc.synod", "Edited demo.synod"); nil for
    /// other events.
    public var progressLine: String? {
        guard case .toolUse(_, let name, let s) = self else { return nil }
        return ClaudeProgress.line(tool: name, summary: s)
    }
}

public enum ClaudeProgress {
    /// Maps a tool name (built-in or `mcp__server__tool`) and its input summary to a line.
    public static func line(tool: String, summary: String) -> String {
        func with(_ verb: String) -> String { summary.isEmpty ? verb : "\(verb) \(summary)" }
        switch tool {
        case "Read": return with("Read")
        case "Glob", "Grep": return with("Searched")
        case "Write": return with("Wrote")
        case "Edit", "MultiEdit": return with("Edited")
        case "Bash": return with("Ran")
        default: break
        }
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.first ?? ""
            let name = parts.dropFirst().joined(separator: "__")
            if server == "synod-editor" {
                switch name {
                case "apply_edits", "replace_buffer": return with("Edited")
                case "read_buffer": return with("Read")
                case "create_file": return with("Created")
                case "save_files": return with("Saved")
                case "get_diagnostics": return with("Checked")
                case "open_file": return with("Opened")
                case "list_files": return "Listed files"
                case "get_selection": return "Read the selection"
                default: return with(name)
                }
            }
            if server == "synod" {
                switch name {
                case "run_summary": return with("Ran synod run")
                case "doc", "explain", "check", "fmt": return with("Ran synod \(name)")
                default: break
                }
            }
            return with(name)
        }
        return with(tool)
    }
}

/// Parses the lines of `claude --output-format stream-json`. Tolerant: unknown types give
/// `.other`, malformed lines give nothing.
public struct ClaudeStreamParser: Sendable {
    /// Paths in tool inputs are made relative to this folder.
    public let moduleRoot: URL?

    public init(moduleRoot: URL? = nil) { self.moduleRoot = moduleRoot }

    /// One line can carry several content items.
    public func parse(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String {
                return [.initialized(sessionID: id, model: obj["model"] as? String)]
            }
            return [.other]
        case "assistant":
            let items = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            var events: [ClaudeEvent] = []
            for item in items {
                switch item["type"] as? String {
                case "text":
                    if let t = item["text"] as? String, !t.isEmpty { events.append(.text(t)) }
                case "tool_use":
                    let name = item["name"] as? String ?? ""
                    let input = item["input"] as? [String: Any] ?? [:]
                    events.append(.toolUse(id: item["id"] as? String, name: name, inputSummary: summary(input)))
                default: break
                }
            }
            return events.isEmpty ? [.other] : events
        case "user":
            let content = (obj["message"] as? [String: Any])?["content"]
            guard let items = content as? [[String: Any]] else { return [.other] }
            let events = items.compactMap { item -> ClaudeEvent? in
                guard item["type"] as? String == "tool_result" else { return nil }
                return .toolResult(toolUseID: item["tool_use_id"] as? String, isError: item["is_error"] as? Bool ?? false)
            }
            return events.isEmpty ? [.other] : events
        case "result":
            let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
            return [.result(isError: isError, text: obj["result"] as? String ?? "",
                            sessionID: obj["session_id"] as? String,
                            durationMs: (obj["duration_ms"] as? NSNumber)?.intValue)]
        default:
            return [.other]
        }
    }

    private func summary(_ input: [String: Any]) -> String {
        for key in ["file_path", "path"] {
            if let p = input[key] as? String { return relative(p) }
        }
        if let ps = input["paths"] as? [String], !ps.isEmpty { return ps.map(relative).joined(separator: ", ") }
        for key in ["command", "pattern", "program", "package", "target", "code"] {
            if let s = input[key] as? String { return s }
        }
        return ""
    }

    private func relative(_ path: String) -> String {
        guard let root = moduleRoot?.standardizedFileURL.path, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// True when a result text means Claude Code is not logged in.
    public static func isLoginProblem(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("/login") || t.contains("not logged in") || t.contains("invalid api key")
            || t.contains("authentication") || t.contains("please run claude")
    }

    public static let loginMessage = "Run `claude` once in Terminal to log in."
}
