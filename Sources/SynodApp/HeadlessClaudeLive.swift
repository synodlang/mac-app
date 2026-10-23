import AppKit
import Foundation
import SynodCore

/// `--claude-live <module> --request "<text>" [--model m] [--timeout s]`: a dev aid. Runs the real prompt-bar
/// path (editor MCP listener, bridge, `ClaudeInvocation`) against the user's own Claude Code on a temporary
/// copy of the module, and prints the argv, every stream-json line, stderr and the exit status. It costs real
/// usage: one request per run. The copy is kept and its path printed.
enum HeadlessClaudeLive {
    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--claude-live", in: args).first, let request = h.value(of: "--request", in: args) else {
            h.fail("usage: --claude-live <module> --request \"<text>\" [--model m] [--timeout seconds]")
            return 2
        }
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        guard let claude = ClaudeLocator.resolve(setting: ""), let bridge = HelperTools.editorBridge(),
              let skills = HelperTools.agentSkills(tools: tools), ClaudeInvocation.loadSkill(from: skills) != nil else {
            h.fail("claude, the editor bridge or the agent skills were not found")
            return 2
        }
        let rig: HeadlessLearning.Rig
        do { rig = try HeadlessLearning.Rig(module: modulePath) } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        let hub = EditorMCPHub()
        let model = rig.model
        hub.windows = { [model] }
        model.claude.hub = hub
        model.claude.isEnabled = { true }
        let timeout = Int(h.value(of: "--timeout", in: args) ?? "") ?? 600
        let m = h.value(of: "--model", in: args)
        model.claude.config = {
            ClaudeModel.Config(claude: claude, model: m ?? ClaudeInvocation.defaultModel, skills: skills, synod: tools.synod, bridge: bridge,
                               timeout: .seconds(timeout))
        }
        model.claude.argvTap = { inv in
            print("claude: \(inv.claude.path)")
            print("cwd: \(inv.workingDirectory.path)")
            print("argv (system prompt shortened): " + inv.arguments.map { $0.count > 120 ? String($0.prefix(60)) + "...(\($0.count) chars)" : $0 }.joined(separator: " "))
            print("env keys: " + inv.environment.keys.sorted().joined(separator: ","))
            fflush(stdout)
        }
        model.claude.rawLineTap = { print("OUT " + $0); fflush(stdout) }
        model.claude.exitTap = { e in
            print("EXIT status=\(e.status) stopped=\(e.stopped) timedOut=\(e.timedOut)")
            print("STDERR<<\n\(e.stderr)\n>>")
            fflush(stdout)
        }
        if let first = rig.model.workspace.scan().programs.first { try? await rig.select(first) }
        print("module copy: \(rig.root.path)")
        let r = await model.claude.send(request)
        print("send: \(r)")
        _ = await model.claude.waitUntilIdle(timeout: Double(timeout) + 30)
        print("progress: \(model.claude.progress)")
        print("error: \(model.claude.errorText ?? "none")")
        print("final: \(model.claude.finalText ?? "none")")
        print("changed: \(model.claude.changed)")
        return model.claude.errorText == nil ? 0 : 1
    }
}
