import Foundation
import SynodCore

/// `Synod --m10 <examples module> --out <dir> [--quick] [--claude <fake-claude>] [--golden tools.json] [--bridge b] [--skills s]`:
/// the M10 headless acceptance (plan section 6 checks 9, 10 and 12, addendum A10 items 14 and 15).
/// It runs `--completion-check`, `--claude-check` (against the fake `claude`), `--mcp-check`, then `--m9`
/// (`--quick` passes `--quick` on), and writes `<out>/report-m10.json`.
@MainActor
enum AcceptanceM10 {
    struct Section: Codable {
        var name: String
        var ok: Bool
        var exitCode: Int32
        var seconds: Double
        var report: String
    }

    struct Completion: Codable { var ok: Bool }

    struct Claude: Codable {
        var ok: Bool
        var argvMatch: Bool
        var envAllowlistOk: Bool
        var noWriteEditTools: Bool
        var mcpUndoGroups: Int
        var revertBytesEqual: Bool
        var resumeOk: Bool
        var stopSeconds: Double
        var stopOk: Bool
        var settingOffNeverLaunches: Bool
    }

    struct MCP: Codable {
        var ok: Bool
        var toolsMatchGolden: Bool
        var tcpListeners: Int
        var socketRemoved: Bool
        var configRemoved: Bool
        var externalOk: Bool
    }

    struct M9: Codable {
        var ok: Bool
        var quick: Bool
        var report: String
    }

    struct Revert: Codable { var bytesEqual: Bool }

    struct Report: Codable {
        var pass: Bool
        var quick: Bool
        var seconds: Double
        var completion: Completion
        var claude: Claude
        var mcp: MCP
        var revert: Revert
        var stopSeconds: Double
        var m9: M9
        var m9quick: M9?
        var sections: [Section]
    }

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let module = h.positionals(after: "--m10", in: args).first, let outPath = h.value(of: "--out", in: args) else {
            h.fail("usage: --m10 <module> --out <dir> [--quick] [--claude <fake-claude>] [--golden tools.json] [--bridge b] [--skills s]")
            return 2
        }
        let quick = args.contains("--quick")
        let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        do { try fm.createDirectory(at: out, withIntermediateDirectories: true) } catch {
            h.fail("cannot create \(out.path): \(error.localizedDescription)")
            return 2
        }
        // The environment-allowlist check needs a variable the child must not see.
        setenv("SYNOD_SECRET_SENTINEL", "m10-sentinel", 1)
        let passthrough = ["--claude", "--golden", "--bridge", "--skills"].flatMap { flag in
            h.value(of: flag, in: args).map { [flag, $0] } ?? []
        }
        let started = ContinuousClock.now
        var sections: [Section] = []

        func section(_ name: String, report file: String, _ body: (String) async -> Int32) async -> HeadlessEditor.Report? {
            let path = out.appendingPathComponent(file).path
            try? fm.removeItem(atPath: path)
            h.note("m10: \(name)")
            let t0 = ContinuousClock.now
            let code = await body(path)
            let secs = seconds(since: t0)
            let report = fm.contents(atPath: path).flatMap { try? JSONDecoder().decode(HeadlessEditor.Report.self, from: $0) }
            let ok = code == 0 && (report?.ok ?? false)
            h.note("m10: \(ok ? "ok  " : "FAIL") \(name) (\(String(format: "%.1f", secs)) s)")
            sections.append(Section(name: name, ok: ok, exitCode: code, seconds: secs, report: file))
            return report
        }

        let completion = await section("completion", report: "completion.json") { r in
            await HeadlessCompletion.run(["--completion-check", module, "--report", r])
        }
        let claude = await section("prompt bar with fake-claude", report: "claude.json") { r in
            await HeadlessClaude.run(["--claude-check", module, "--report", r] + passthrough.filter { $0 != "--golden" && $0 != "--bridge" })
        }
        let mcp = await section("editor MCP server", report: "mcp.json") { r in
            await HeadlessMCP.run(["--mcp-check", module, "--report", r] + passthrough.filter { $0 == "--golden" || $0 == "--bridge" })
        }

        // M9 (which includes the M8 smoke test and video) runs last; its own report stays in <out>/m9.
        let m9dir = out.appendingPathComponent("m9")
        h.note("m10: m9\(quick ? " (quick)" : "")")
        let m9t0 = ContinuousClock.now
        let m9code = await AcceptanceM9.run(["--m9", module, "--out", m9dir.path] + (quick ? ["--quick"] : []))
        let m9pass = m9code == 0 && ((fm.contents(atPath: m9dir.appendingPathComponent("report-m9.json").path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["pass"] as? Bool) == true
        sections.append(Section(name: quick ? "m9 (quick)" : "m9", ok: m9pass, exitCode: m9code, seconds: seconds(since: m9t0), report: "m9/report-m9.json"))
        h.note("m10: \(m9pass ? "ok  " : "FAIL") m9")

        func check(_ report: HeadlessEditor.Report?, _ prefix: String) -> HeadlessEditor.Check? {
            report?.checks.first { $0.name.hasPrefix(prefix) }
        }
        func ok(_ report: HeadlessEditor.Report?, _ prefix: String) -> Bool { check(report, prefix)?.ok ?? false }

        let argv = check(claude, "argv, cwd and environment")
        let edits = check(claude, "MCP edits, progress")
        let stopMs = check(claude, "Stop")?.metrics["stopMs"] ?? .infinity
        let life = check(mcp, "no TCP listener")
        let claudeOut = Claude(
            ok: claude?.ok ?? false,
            argvMatch: argv.map { $0.ok && !$0.failures.contains { $0.hasPrefix("argv differs") || $0.hasPrefix("no --") } } ?? false,
            envAllowlistOk: argv.map { $0.ok && !$0.failures.contains { $0.hasPrefix("environment has") || $0.contains("leaked") } } ?? false,
            noWriteEditTools: argv.map { !$0.failures.contains { $0.contains("Write or Edit") } } == true
                && edits.map { !$0.failures.contains { $0.contains("Write or Edit") } } == true,
            mcpUndoGroups: Int(edits?.metrics["mcpUndoGroups"] ?? 0),
            revertBytesEqual: ok(claude, "banner and Revert"),
            resumeOk: ok(claude, "follow-up uses --resume"),
            stopSeconds: (stopMs / 10).rounded() / 100,
            stopOk: ok(claude, "Stop"),
            settingOffNeverLaunches: ok(claude, "setting off"))
        let mcpOut = MCP(
            ok: mcp?.ok ?? false,
            toolsMatchGolden: ok(mcp, "tools/list equals the golden"),
            tcpListeners: Int(life?.metrics["tcpListeners"] ?? -1),
            socketRemoved: (life?.metrics["socketRemoved"] ?? 0) == 1,
            configRemoved: (life?.metrics["configRemoved"] ?? 0) == 1,
            externalOk: ok(mcp, "external access"))
        let m9out = M9(ok: m9pass, quick: quick, report: "m9/report-m9.json")
        let pass = sections.allSatisfy(\.ok) && (completion?.ok ?? false) && claudeOut.noWriteEditTools && claudeOut.mcpUndoGroups >= 1
            && claudeOut.stopOk && mcpOut.tcpListeners == 0 && mcpOut.socketRemoved && mcpOut.configRemoved && mcpOut.toolsMatchGolden
        let report = Report(
            pass: pass, quick: quick, seconds: seconds(since: started),
            completion: Completion(ok: completion?.ok ?? false), claude: claudeOut, mcp: mcpOut,
            revert: Revert(bytesEqual: claudeOut.revertBytesEqual), stopSeconds: claudeOut.stopSeconds,
            m9: m9out, m9quick: quick ? m9out : nil, sections: sections)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(report).write(to: out.appendingPathComponent("report-m10.json"))
        } catch {
            h.fail("cannot write report-m10.json: \(error.localizedDescription)")
            return 2
        }
        h.note("m10: \(pass ? "PASS" : "FAIL") (\(sections.filter(\.ok).count)/\(sections.count) sections, \(String(format: "%.0f", report.seconds)) s)")
        for s in sections where !s.ok { h.note("  failed: \(s.name)") }
        return pass ? 0 : 1
    }

    private static func seconds(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
