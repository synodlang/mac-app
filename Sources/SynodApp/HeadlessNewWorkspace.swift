import Foundation
import SynodCore

/// `--new-workspace-check [--report f]`: New Workspace on a temporary folder through the same code
/// path as the menu (`NewWorkspaceFlow.create`). The folder gets a `synod.mod`, a package folder and a
/// demo program that `synod check` accepts; a library has no program; an existing folder with files is
/// refused without touching it; a bad module path shows synod's message.
enum HeadlessNewWorkspace {
    struct Check: Codable {
        var name: String
        var ok = false
        var failures: [String] = []
    }

    struct Report: Codable {
        var ok: Bool
        var checks: [Check]
    }

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let env = AppEnvironment.shared
        guard env.runner != nil else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("synod-new-workspace-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let runner = SynodRunner(executable: tools.synod)

        var checks: [Check] = []
        checks.append(await appCheck(scratch.appendingPathComponent("My App"), env: env, runner: runner))
        checks.append(await libraryCheck(scratch.appendingPathComponent("lib"), env: env, runner: runner))
        checks.append(await failureCheck(scratch, env: env))
        for c in checks {
            h.note("\(c.ok ? "ok  " : "FAIL") new-workspace-check \(c.name)\(c.failures.isEmpty ? "" : "  " + c.failures.joined(separator: "; "))")
        }
        let report = Report(ok: checks.allSatisfy(\.ok), checks: checks)
        if let path = h.value(of: "--report", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(report).write(to: URL(fileURLWithPath: path))
        }
        return report.ok ? 0 : 1
    }

    @MainActor private static func make(_ dir: URL, module: String, lib: Bool, env: AppEnvironment) async -> (URL?, [String]) {
        var errors: [String] = []
        let url = await NewWorkspaceFlow.create(.init(directory: dir, module: module, isLibrary: lib), env: env) { errors.append($0) }
        return (url, errors)
    }

    /// A folder name with a space and capitals, and the default module path.
    @MainActor private static func appCheck(_ dir: URL, env: AppEnvironment, runner: SynodRunner) async -> Check {
        var c = Check(name: "program workspace")
        let fm = FileManager.default
        let (url, errors) = await make(dir, module: "", lib: false, env: env)
        if !errors.isEmpty { c.failures.append("errors: \(errors)") }
        guard let url else { c.failures.append("no workspace"); return c }
        if !fm.fileExists(atPath: url.appendingPathComponent("synod.mod").path) { c.failures.append("no synod.mod") }
        let mod = (try? String(contentsOf: url.appendingPathComponent("synod.mod"), encoding: .utf8)) ?? ""
        if !mod.contains("module example.com/myapp") { c.failures.append("module line: \(mod)") }
        guard let ws = try? Workspace.open(url) else { c.failures.append("not a workspace"); return c }
        let scan = ws.scan()
        if scan.programs.map(\.relPath) != ["myapp"] { c.failures.append("programs \(scan.programs.map(\.relPath))") }
        if !fm.fileExists(atPath: url.appendingPathComponent("myapp/demo.synod").path) { c.failures.append("no myapp/demo.synod") }
        // The model has to open on the demo program: the hand-off is waiting for the window.
        if env.takeNewWorkspace(at: url)?.file != "myapp/demo.synod" { c.failures.append("hand-off is not myapp/demo.synod") }
        if let r = try? await runner.exec(["check", "."], cwd: url), r.exitCode != 0 {
            c.failures.append("synod check: \(r.stderrText)\(r.stdoutText)")
        }
        c.ok = c.failures.isEmpty
        return c
    }

    @MainActor private static func libraryCheck(_ dir: URL, env: AppEnvironment, runner: SynodRunner) async -> Check {
        var c = Check(name: "library workspace")
        let (url, errors) = await make(dir, module: "example.org/kit", lib: true, env: env)
        if !errors.isEmpty { c.failures.append("errors: \(errors)") }
        guard let url, let ws = try? Workspace.open(url) else { c.failures.append("no workspace"); return c }
        let scan = ws.scan()
        if !scan.programs.isEmpty { c.failures.append("a library has programs") }
        if scan.packages.map(\.relPath) != ["kit"] { c.failures.append("packages \(scan.packages.map(\.relPath))") }
        if env.takeNewWorkspace(at: url)?.package != "kit" { c.failures.append("hand-off is not the package kit") }
        if let r = try? await runner.exec(["check", "."], cwd: url), r.exitCode != 0 {
            c.failures.append("synod check: \(r.stderrText)\(r.stdoutText)")
        }
        c.ok = c.failures.isEmpty
        return c
    }

    @MainActor private static func failureCheck(_ scratch: URL, env: AppEnvironment) async -> Check {
        var c = Check(name: "errors")
        let fm = FileManager.default
        let busy = scratch.appendingPathComponent("busy")
        try? fm.createDirectory(at: busy, withIntermediateDirectories: true)
        try? "keep".write(to: busy.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let (a, e1) = await make(busy, module: "", lib: false, env: env)
        if a != nil || e1.count != 1 || !e1[0].contains("not empty") { c.failures.append("non-empty folder: \(e1)") }
        if (try? String(contentsOf: busy.appendingPathComponent("notes.txt"), encoding: .utf8)) != "keep" || fm.fileExists(atPath: busy.appendingPathComponent("synod.mod").path) {
            c.failures.append("the existing folder was touched")
        }
        let (b, e2) = await make(scratch.appendingPathComponent("bad"), module: "example.com/2bad", lib: false, env: env)
        if b != nil || e2.count != 1 || !e2[0].contains("package name") { c.failures.append("bad module: \(e2)") }
        c.ok = c.failures.isEmpty
        return c
    }
}
