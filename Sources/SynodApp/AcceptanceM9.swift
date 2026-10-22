import Foundation
import SynodCore

/// `Synod --m9 <examples module> --out <dir> [--quick]`: the whole M9 acceptance on the bundled
/// examples. It runs the editor, Predict, hit, Break it, Compare and GIF checks through the same
/// entry points as their own flags, then the M8 smoke test and Raft video acceptance, and writes
/// `<out>/report-m9.json`. `--quick` is the pull-request variant: tcp only for the Predict, hit and
/// GIF checks and the video; the editor, Break it (cassandra) and Compare (raft, 3 s) checks always run in full.
@MainActor
enum AcceptanceM9 {
    struct Entry: Codable {
        var name: String
        var ok: Bool
        var exitCode: Int32
        var seconds: Double
        var report: String
        var checks: [Item]
    }

    struct Item: Codable {
        var name: String
        var ok: Bool
        var failures: [String]
        var metrics: [String: Double]
    }

    struct Report: Codable {
        var pass: Bool
        var quick: Bool
        var seconds: Double
        var sections: [Entry]
        var thresholds: [String: Double]
        var artifacts: [String]
    }

    /// The part of a check report this runner needs (all the learning and editor reports share it).
    private struct Shape: Decodable {
        struct C: Decodable {
            var name: String
            var ok: Bool
            var failures: [String]?
            var metrics: [String: Double]?
        }
        var ok: Bool
        var checks: [C]?
    }

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let module = h.positionals(after: "--m9", in: args).first, let outPath = h.value(of: "--out", in: args) else {
            h.fail("usage: --m9 <module> --out <dir> [--quick]")
            return 2
        }
        let quick = args.contains("--quick")
        let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        do { try fm.createDirectory(at: out, withIntermediateDirectories: true) } catch {
            h.fail("cannot create \(out.path): \(error.localizedDescription)")
            return 2
        }
        let programFilter: [String] = quick ? ["--program", "tcp"] : []
        let script = h.value(of: "--script", in: args) ?? "Tests/Acceptance/cassandra-handoff.json"
        let gif = out.appendingPathComponent("tcp.gif").path
        try? fm.removeItem(atPath: gif)
        let started = ContinuousClock.now
        var sections: [Entry] = []

        func section(_ name: String, report file: String, _ body: (String) async -> Int32) async {
            let path = out.appendingPathComponent(file).path
            h.note("m9: \(name)")
            let t0 = ContinuousClock.now
            let code = await body(path)
            let seconds = seconds(since: t0)
            var items: [Item] = []
            var ok = code == 0
            if let data = fm.contents(atPath: path), let shape = try? JSONDecoder().decode(Shape.self, from: data) {
                ok = ok && shape.ok
                items = (shape.checks ?? []).map { Item(name: $0.name, ok: $0.ok, failures: $0.failures ?? [], metrics: $0.metrics ?? [:]) }
            }
            if items.isEmpty, let data = fm.contents(atPath: path), let m8 = try? JSONDecoder().decode(Acceptance.Report.self, from: data) {
                ok = ok && m8.pass
                items = [Item(name: "\(m8.program) video", ok: m8.pass, failures: m8.failures,
                              metrics: ["frames": Double(m8.frames), "minPSNR": m8.minPSNR, "medianPSNR": m8.medianPSNR,
                                        "maxMAD": m8.maxMAD, "exportSeconds": m8.exportSeconds])]
            }
            h.note("m9: \(ok ? "ok  " : "FAIL") \(name) (\(String(format: "%.1f", seconds)) s)")
            sections.append(Entry(name: name, ok: ok, exitCode: code, seconds: seconds, report: file, checks: items))
        }

        await section("editor", report: "editor.json") { r in
            await HeadlessEditor.run(["--editor-check", module, "--report", r])
        }
        await section("predict choices", report: "predict.json") { r in
            await HeadlessLearning.predictCheck(["--predict-check", module, "--report", r] + programFilter)
        }
        await section("hit test and click to select", report: "hit.json") { r in
            await HeadlessLearning.hitCheck(["--hit-check", module, "--report", r] + programFilter)
        }
        await section("break it (cassandra hinted handoff)", report: "breakit.json") { r in
            await HeadlessLearning.breakItCheck(["--breakit-check", module, "--script", script, "--report", r])
        }
        await section("compare raft", report: "compare.json") { r in
            await HeadlessLearning.compareCheck(["--compare-check", module, "raft", "--seeds", "3,4", "--report", r])
        }
        await section("gif export", report: "gif-export.json") { r in
            let code = await h.export(["--export", module, "tcp", "--out", gif, "--width", "640", "--fps", "20", "--rate", "1"])
            let ok = code == 0 && fm.fileExists(atPath: gif)
            let json = "{\"ok\": \(ok), \"checks\": [{\"name\": \"tcp.gif exported\", \"ok\": \(ok), \"failures\": [], \"metrics\": {}}]}"
            try? Data(json.utf8).write(to: URL(fileURLWithPath: r))
            return ok ? 0 : 1
        }
        await section("gif check", report: "gif.json") { r in
            await HeadlessLearning.gifCheck(["--gif-check", gif, "--module", module, "--program", "tcp", "--samples", "10", "--report", r])
        }
        await section("m8 smoke and video acceptance\(quick ? " (tcp)" : " (raft)")", report: "m8/report.json") { _ in
            let m8 = out.appendingPathComponent("m8").path
            return await Acceptance.run(["--acceptance", module, "--out", m8] + (quick ? ["--quick"] : []))
        }

        var artifacts = ["tcp.gif"]
        if let items = try? fm.contentsOfDirectory(atPath: out.appendingPathComponent("m8").path) {
            artifacts += items.filter { $0.hasSuffix(".mp4") }.map { "m8/" + $0 }
        }
        let pass = sections.allSatisfy(\.ok)
        let report = Report(
            pass: pass, quick: quick, seconds: seconds(since: started), sections: sections,
            thresholds: ["gifMinPSNR": AcceptanceThresholds.gifMinPSNR, "gifDistinctRefPSNR": AcceptanceThresholds.gifDistinctRefPSNR,
                         "videoMinPSNR": AcceptanceThresholds.minPSNR, "videoMaxMAD": AcceptanceThresholds.maxMAD],
            artifacts: artifacts)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(report).write(to: out.appendingPathComponent("report-m9.json"))
        } catch {
            h.fail("cannot write report-m9.json: \(error.localizedDescription)")
            return 2
        }
        h.note("m9: \(pass ? "PASS" : "FAIL") (\(sections.filter(\.ok).count)/\(sections.count) sections, \(String(format: "%.0f", report.seconds)) s)")
        for s in sections where !s.ok { h.note("  failed: \(s.name)") }
        return pass ? 0 : 1
    }

    private static func seconds(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
