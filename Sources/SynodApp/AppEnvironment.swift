import Foundation
import Observation
import SynodCore

/// Where the compiler and the bundled examples are, shared by the app and the headless modes.
enum AppTools {
    /// The bundle's tools when usable, else the repository's `.deps`; a settings path replaces the compiler.
    static func resolve(override: String? = nil) -> ToolPaths? {
        var base: ToolPaths?
        // A run from the build folder (not an .app) uses the repository's pinned tools first.
        let inBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if !inBundle, let r = ToolPaths.repoDeps() {
            base = r
        } else if let b = ToolPaths.bundled(), b.isUsable {
            base = b
        } else {
            base = ToolPaths.repoDeps()
        }
        guard var tools = base else {
            if let o = override, !o.isEmpty { return ToolPaths(synod: URL(fileURLWithPath: o)).overriding(synodPath: o) }
            return nil
        }
        tools = tools.overriding(synodPath: override)
        return tools
    }
}

/// Where the editor bridge (`synod-editor-mcp`) and the fake `claude` of the checks are.
enum HelperTools {
    /// `Contents/Helpers/synod-editor-mcp` in the app bundle, else next to the running executable
    /// (a `swift build` folder), else `SYNOD_EDITOR_BRIDGE`.
    static func editorBridge() -> URL? { helper("synod-editor-mcp", override: "SYNOD_EDITOR_BRIDGE") }

    static func helper(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let o = override, let p = ProcessInfo.processInfo.environment[o], !p.isEmpty { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"))
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name)) }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// The agent-skills folder: `SYNOD_AGENT_SKILLS`, else the bundled or `.deps` one.
    static func agentSkills(tools: ToolPaths?) -> URL? {
        if let p = ProcessInfo.processInfo.environment["SYNOD_AGENT_SKILLS"], !p.isEmpty {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("skills/synod/SKILL.md").path) { return url }
        }
        return tools?.agentSkills
    }
}

/// App-wide state: the compiler, its version check, the recent workspaces.
@MainActor @Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    static let overrideKey = "synodPathOverride"
    static let recentsKey = "recentWorkspaces"
    static let promptBarKey = "promptBarEnabled"
    static let claudePathKey = "claudePath"
    static let claudeModelKey = "claudeModel"

    private(set) var tools: ToolPaths?
    private(set) var runner: SynodRunner?
    private(set) var version: SynodVersion?
    private(set) var versionProblem: String?
    private(set) var recents: [String]
    private var probed = false

    /// Settings › Claude (decision 96). The prompt bar is off until the user opts in.
    var promptBarEnabled: Bool {
        didSet { UserDefaults.standard.set(promptBarEnabled, forKey: Self.promptBarKey) }
    }
    var claudePath: String {
        didSet {
            UserDefaults.standard.set(claudePath, forKey: Self.claudePathKey)
            probeClaude()
        }
    }
    /// Empty means Claude Code's own default model.
    var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: Self.claudeModelKey) }
    }
    private(set) var claudeURL: URL?
    private(set) var claudeVersion: String?
    private(set) var claudeProbed = false

    var synodPathOverride: String {
        didSet {
            UserDefaults.standard.set(synodPathOverride, forKey: Self.overrideKey)
            reload()
        }
    }

    private init() {
        synodPathOverride = UserDefaults.standard.string(forKey: Self.overrideKey) ?? ""
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        promptBarEnabled = UserDefaults.standard.bool(forKey: Self.promptBarKey)
        claudePath = UserDefaults.standard.string(forKey: Self.claudePathKey) ?? ""
        claudeModel = UserDefaults.standard.string(forKey: Self.claudeModelKey) ?? ClaudeInvocation.defaultModel
        configureTools()
        claudeURL = ClaudeLocator.resolve(setting: claudePath)
    }

    private func configureTools() {
        tools = AppTools.resolve(override: synodPathOverride)
        if let t = tools, t.isUsable {
            runner = SynodRunner(executable: t.synod)
        } else {
            runner = nil
        }
    }

    func reload() {
        configureTools()
        probed = false
        version = nil
        versionProblem = nil
        probeIfNeeded()
    }

    func probeIfNeeded() {
        guard !probed else { return }
        probed = true
        guard let runner else {
            versionProblem = "The synod compiler was not found. Set its path in Settings."
            return
        }
        Task {
            do {
                let v = try await SynodVersion.probe(runner)
                version = v
                versionProblem = v.problem
            } catch {
                versionProblem = "Could not run the compiler: \(error.localizedDescription)"
            }
        }
    }

    var examplesURL: URL? { tools?.examples }

    /// Completion needs `synod-doc/1`; until the version is known it is on.
    var completionEnabled: Bool { version?.supportsDoc ?? true }

    var skillsURL: URL? { HelperTools.agentSkills(tools: tools) }

    /// Finds `claude` (the path setting, else the usual places) and asks it for its version.
    func probeClaude() {
        claudeURL = ClaudeLocator.resolve(setting: claudePath)
        claudeVersion = nil
        claudeProbed = false
        guard let claude = claudeURL, let synod = tools?.synod else { claudeProbed = true; return }
        Task {
            let v = await ClaudeLocator.version(of: claude, synod: synod)
            if claudeURL == claude {
                claudeVersion = v
                claudeProbed = true
            }
        }
    }

    func probeClaudeIfNeeded() {
        if !claudeProbed && claudeVersion == nil { probeClaude() }
    }

    /// Why the prompt bar cannot start a request, or nil.
    var promptBarProblem: String? {
        if claudeURL == nil {
            return "Claude Code was not found. Install it from https://claude.com/product/claude-code, then set its path in Settings > Claude."
        }
        if skillsURL == nil { return "The bundled agent skills were not found." }
        if tools?.synod == nil || runner == nil { return "The synod compiler was not found." }
        if HelperTools.editorBridge() == nil { return "The editor bridge (synod-editor-mcp) was not found." }
        return nil
    }

    func addRecent(_ url: URL) {
        let p = url.standardizedFileURL.path
        recents.removeAll { $0 == p }
        recents.insert(p, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }
}

/// A workspace path given on the command line (`Synod.app --args <folder>`), if any.
enum LaunchArguments {
    /// Never shown; stands in for "no workspace" in the workspace window group.
    static let placeholder = URL(fileURLWithPath: "/dev/null")

    /// Set once the launch folder has been opened, so it is not opened again.
    @MainActor static var routed = false

    /// Hidden dev aid (the live acceptance script): `--workspace-file <path>` makes the app write the folder of
    /// the workspace window it opens (and its pid) to that file, so a script can check what is on screen.
    static let workspaceFileOption = "--workspace-file"

    static var workspaceFile: URL? {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let i = args.firstIndex(of: workspaceFileOption), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// Records the opened workspace for `--workspace-file`.
    static func recordWorkspace(_ root: URL) {
        guard let file = workspaceFile else { return }
        let text = "\(getpid())\n\(root.resolvingSymlinksInPath().path)\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    static var workspaceURL: URL? { workspaceURL(in: Array(CommandLine.arguments.dropFirst())) }

    /// The first argument that is not an option (or macOS's `-NS...` defaults pairs) and names an existing path.
    static func workspaceURL(in args: [String], exists: (String) -> Bool? = isDirectory) -> URL? {
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = a.hasPrefix("-NS") || a.hasPrefix("-Apple") || a == workspaceFileOption; continue }
            let path = (a as NSString).expandingTildeInPath
            if let isDir = exists(path) { return URL(fileURLWithPath: path, isDirectory: isDir) }
        }
        return nil
    }

    nonisolated static func isDirectory(_ path: String) -> Bool? {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) ? isDir.boolValue : nil
    }
}
