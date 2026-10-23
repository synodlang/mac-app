import Foundation

/// How the app runs the user's `claude` (plan 1.6 with addendum A6). Pure: it only builds the
/// program, argument list, environment and working directory.
public struct ClaudeInvocation: Sendable, Equatable {
    /// The built-in tools that exist at all (`--tools` restricts the set; `--allowedTools` only pre-approves).
    /// MCP tools are not built-in, so the lists below still govern them. No Bash: `synod get` is the user's step.
    public static let builtinTools = "Read,Glob,Grep"
    public static let allowedTools = "Read,Glob,Grep,mcp__synod-editor__*,mcp__synod__doc,mcp__synod__explain,mcp__synod__check,mcp__synod__run_summary"
    public static let disallowedTools = "Write,Edit,MultiEdit,NotebookEdit,WebFetch,WebSearch,Bash,Agent,Task,mcp__synod__fmt"
    public static let editorPrompt = "In this workspace, edit Synod files only with the synod-editor tools: read_buffer before editing, apply_edits or replace_buffer to change, create_file for new files, get_diagnostics (fresh) until clean, then save_files, and only then run_summary. Use the synod tools for doc, explain, check and run_summary."
    public static let defaultModel = "claude-opus-5-5"

    /// Host variables copied when set. Nothing else is passed: the app hands Claude Code no credential of any kind.
    public static let inheritedVariables = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR"]
    public static let fixedPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public var claude: URL
    public var request: String
    /// The module root: the working directory.
    public var workingDirectory: URL
    /// The 0600 MCP config file of this request.
    public var mcpConfig: URL
    /// The agent-skills folder (it holds `skills/synod`).
    public var skillsFolder: URL
    /// SKILL.md as read from disk (front matter is stripped here).
    public var skillMarkdown: String
    /// The bundled `synod`, whose folder leads PATH.
    public var synod: URL
    /// Empty or nil means Claude Code's own default.
    public var model: String?
    public var sessionID: String?
    /// The app's own environment, filtered by the allowlist.
    public var hostEnvironment: [String: String]

    public init(claude: URL, request: String, workingDirectory: URL, mcpConfig: URL, skillsFolder: URL,
                skillMarkdown: String, synod: URL, model: String? = nil, sessionID: String? = nil,
                hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.claude = claude
        self.request = request
        self.workingDirectory = workingDirectory
        self.mcpConfig = mcpConfig
        self.skillsFolder = skillsFolder
        self.skillMarkdown = skillMarkdown
        self.synod = synod
        self.model = model
        self.sessionID = sessionID
        self.hostEnvironment = hostEnvironment
    }

    public var skillFolder: URL { skillsFolder.appendingPathComponent("skills/synod") }

    /// SKILL.md without its `---` front matter.
    public static func stripFrontMatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return markdown
        }
        var rest = Array(lines[(end + 1)...])
        while rest.first?.isEmpty == true { rest.removeFirst() }
        return rest.joined(separator: "\n")
    }

    /// The text of `--append-system-prompt`.
    public var systemPrompt: String {
        Self.stripFrontMatter(skillMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nThe reference files are in \(skillFolder.path)/reference/.\n\n" + Self.editorPrompt
    }

    /// The arguments after the program.
    public var arguments: [String] {
        // A request that starts with "-" must not read as a flag.
        let prompt = request.hasPrefix("-") ? " " + request : request
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--append-system-prompt", systemPrompt,
                    "--add-dir", skillFolder.path,
                    "--mcp-config", mcpConfig.path, "--strict-mcp-config",
                    "--tools", Self.builtinTools,
                    "--allowedTools", Self.allowedTools,
                    "--disallowedTools", Self.disallowedTools]
        if let m = model?.trimmingCharacters(in: .whitespaces), !m.isEmpty { args += ["--model", m] }
        if let s = sessionID, !s.isEmpty { args += ["--resume", s] }
        return args
    }

    public var environment: [String: String] {
        Self.environment(host: hostEnvironment, synod: synod, claude: claude)
    }

    /// The allowlisted environment.
    public static func environment(host: [String: String], synod: URL, claude: URL) -> [String: String] {
        var env: [String: String] = [:]
        for k in inheritedVariables { if let v = host[k] { env[k] = v } }
        let dirs = [synod.deletingLastPathComponent().path, claude.deletingLastPathComponent().path] + fixedPath
        env["PATH"] = dirs.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    /// Reads `<skillsFolder>/skills/synod/SKILL.md`.
    public static func loadSkill(from skillsFolder: URL) -> String? {
        try? String(contentsOf: skillsFolder.appendingPathComponent("skills/synod/SKILL.md"), encoding: .utf8)
    }

    /// The preset "Explain this run" (plan 1.6 step 9).
    public static func explainRunPrompt(program: String, mainFile: String) -> String {
        "Explain this run: run \"synod run \(program) --summary\", then add lesson.Note lines to define main in \(mainFile) that caption what happens, at the times it happens. Do not change the behaviour."
    }
}
