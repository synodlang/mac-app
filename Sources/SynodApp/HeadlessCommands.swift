import Foundation
import SynodCore
import SynodWeb

/// The hidden command-line modes: `--smoke`, `--export`, `--acceptance` and the checks of the editor and
/// the learning modes (`HeadlessEditor`, `HeadlessLearning`).
enum HeadlessCommands {
    static func run(_ args: [String]) async -> Int32 {
        if args.contains("--smoke") { return await smoke(args) }
        if args.contains("--stage-check") { return await StageCheck.run(args) }
        if args.contains("--editor-check") { return await HeadlessEditor.run(args) }
        if args.contains("--completion-check") { return await HeadlessCompletion.run(args) }
        if args.contains("--claude-check") { return await HeadlessClaude.run(args) }
        if args.contains("--mcp-check") { return await HeadlessMCP.run(args) }
        if args.contains("--predict-check") { return await HeadlessLearning.predictCheck(args) }
        if args.contains("--hit-check") { return await HeadlessLearning.hitCheck(args) }
        if args.contains("--breakit-check") { return await HeadlessLearning.breakItCheck(args) }
        if args.contains("--compare-check") { return await HeadlessLearning.compareCheck(args) }
        if args.contains("--gif-check") { return await HeadlessLearning.gifCheck(args) }
        if args.contains("--export") { return await export(args) }
        if args.contains("--m9") { return await AcceptanceM9.run(args) }
        if args.contains("--acceptance") { return await acceptance(args) }
        return 2
    }

    /// `--acceptance <module> --out <dir> [--program raft] [--quick]` (Acceptance.swift).
    static func acceptance(_ args: [String]) async -> Int32 {
        await Acceptance.run(args)
    }

    // MARK: Argument helpers

    static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Positional arguments after `flag`, up to the next `--option`.
    static func positionals(after flag: String, in args: [String]) -> [String] {
        guard let i = args.firstIndex(of: flag) else { return [] }
        return args[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { $0 }
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("Synod: \(message)\n".utf8))
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    struct Context {
        let workspace: Workspace
        let pipeline: RunPipeline
    }

    static func context(module path: String) throws -> Context {
        let workspace = try Workspace.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            throw HeadlessError("the synod compiler was not found")
        }
        let runner = SynodRunner(executable: tools.synod)
        return Context(workspace: workspace, pipeline: RunPipeline(workspace: workspace, runner: runner))
    }

    struct HeadlessError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    // MARK: --smoke

    struct SmokeEntry: Codable {
        var program: String
        var ok: Bool
        var status: String
        var events: Int
        var durationMs: Double
        var warnings: [String]
        var timeEvents: Int
        var pace: Double
        var error: String?
    }

    struct SmokeReport: Codable {
        var ok: Bool
        var module: String
        var programs: [SmokeEntry]
    }

    static let paceRange = 0.9...1.1

    static func smoke(_ args: [String]) async -> Int32 {
        guard let modulePath = positionals(after: "--smoke", in: args).first else {
            fail("usage: --smoke <module> [--report file]")
            return 2
        }
        let ctx: Context
        do { ctx = try context(module: modulePath) } catch {
            fail(error.localizedDescription)
            return 2
        }
        let stage: StageController
        do {
            stage = try StageController(assets: WebAssets.locate(), size: CGSize(width: 960, height: 600), offscreenWindow: true)
            try await stage.waitUntilReady()
        } catch {
            fail("stage failed to start: \(error.localizedDescription)")
            return 1
        }
        // The event stream is single-consumer and ends when its consumer is cancelled, so one task
        // collects for the whole run.
        let box = TimeSamples()
        let collector = Task { @MainActor in
            for await ev in stage.events {
                switch ev {
                case .play: box.started = true
                case .time(let at) where box.started:
                    box.samples.append((at, ProcessInfo.processInfo.systemUptime))
                case .pause(let reason) where box.started && reason == .end:
                    box.ended = true
                case .error(let m):
                    box.errors.append(m)
                default: break
                }
            }
        }
        var entries: [SmokeEntry] = []
        for program in ctx.workspace.scan().programs {
            let entry = await smokeOne(program, ctx: ctx, stage: stage, box: box)
            let pace = String(format: "%.3f", entry.pace)
            note("\(entry.ok ? "ok  " : "FAIL") \(entry.program)  pace \(pace)  \(entry.status)\(entry.error.map { "  " + $0 } ?? "")")
            entries.append(entry)
        }
        stage.tearDown()
        collector.cancel()
        let report = SmokeReport(ok: !entries.isEmpty && entries.allSatisfy(\.ok), module: ctx.workspace.modulePath, programs: entries)
        if let path = value(of: "--report", in: args) {
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(report).write(to: URL(fileURLWithPath: path))
            } catch {
                fail("cannot write report: \(error.localizedDescription)")
                return 1
            }
        }
        return report.ok ? 0 : 1
    }

    @MainActor final class TimeSamples {
        var started = false
        var samples: [(at: Double, wall: Double)] = []
        var ended = false
        var errors: [String] = []
    }

    static func smokeOne(_ program: Workspace.Program, ctx: Context, stage: StageController, box: TimeSamples) async -> SmokeEntry {
        var entry = SmokeEntry(program: program.relPath, ok: false, status: "", events: 0, durationMs: 0, warnings: [], timeEvents: 0, pace: 0, error: nil)
        do {
            let outcome = try await ctx.pipeline.run(program: program)
            guard case .ran(let status, let sceneText, let scene, let trace) = outcome else {
                entry.error = "did not run: \(describe(outcome))"
                return entry
            }
            entry.status = (status.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").components(separatedBy: " -> ").first ?? ""
            entry.events = trace.events.count
            entry.durationMs = scene.duration
            guard case .ok = status.result else { entry.error = "run failed"; return entry }
            if status.lookFault != nil { entry.error = "look failed"; return entry }

            let info = try await stage.setScene(sceneText, keepTime: false)
            try await stage.seek(to: 0)
            try await stage.setRate(1)
            entry.warnings = info.warnings
            if !info.warnings.isEmpty { entry.error = "player warnings: \(info.warnings.joined(separator: "; "))"; return entry }

            box.started = false
            box.samples = []
            box.ended = false
            box.errors = []
            try await stage.play()
            // Short scenes (ring is 1.4 s) are sampled for three quarters of their length so the
            // end of the scene does not distort the pace.
            try await Task.sleep(for: .milliseconds(Int(min(1500, scene.duration * 0.75))))
            try await stage.pause()
            try await Task.sleep(for: .milliseconds(100))
            box.started = false
            if let e = box.errors.first { entry.error = "player error: \(e)" }

            entry.timeEvents = box.samples.count
            if let first = box.samples.first, let last = box.samples.last, last.wall > first.wall {
                entry.pace = (last.at - first.at) / 1000 / (last.wall - first.wall)
            }
            if let lastError = stage.state.lastError { entry.error = "player error: \(lastError)" }
            let increasing = zip(box.samples, box.samples.dropFirst()).allSatisfy { $0.at <= $1.at }
            if box.samples.count < 5 { entry.error = entry.error ?? "only \(box.samples.count) time events" }
            else if !increasing { entry.error = entry.error ?? "time did not increase" }
            else if !paceRange.contains(entry.pace) { entry.error = entry.error ?? "pace outside 0.9..1.1" }
            entry.ok = entry.error == nil
        } catch {
            entry.error = error.localizedDescription
        }
        return entry
    }

    static func describe(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .diagnostics(let r): return "\(r.diagnostics.count) diagnostic(s)"
        case .rawProblems(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ran: return "ran"
        }
    }

    // MARK: --export

    static func export(_ args: [String]) async -> Int32 {
        let pos = positionals(after: "--export", in: args)
        guard pos.count >= 2, let out = value(of: "--out", in: args) else {
            fail("usage: --export <module> <program> --out file.mp4|file.gif [--size 1080p|4k] [--codec h264|hevc] [--fps 60] [--rate 1] [--width 640 --from ms --to ms for a GIF]")
            return 2
        }
        if out.lowercased().hasSuffix(".gif") { return await exportGIF(pos: pos, out: out, args: args) }
        var options = ExportOptions()
        switch value(of: "--size", in: args) ?? "1080p" {
        case "1080p": options.size = .hd1080
        case "4k": options.size = .uhd4k
        default: fail("--size must be 1080p or 4k"); return 2
        }
        switch value(of: "--codec", in: args) ?? "h264" {
        case "h264": options.codec = .h264
        case "hevc": options.codec = .hevc
        default: fail("--codec must be h264 or hevc"); return 2
        }
        if let f = value(of: "--fps", in: args) {
            guard let fps = Int(f), fps > 0 else { fail("--fps must be a number"); return 2 }
            options.fps = fps
        }
        if let r = value(of: "--rate", in: args) {
            guard let rate = Double(r), rate > 0 else { fail("--rate must be a positive number"); return 2 }
            options.rate = rate
        }
        var runOptions = RunOptions()
        if let m = value(of: "--mode", in: args) {
            guard let mode = RunOptions.Mode(rawValue: m) else { fail("--mode must be ordered or proportional"); return 2 }
            runOptions.mode = mode
        }
        if let s = value(of: "--seed", in: args) {
            guard let seed = UInt64(s) else { fail("--seed must be a number"); return 2 }
            runOptions.seed = seed
        }
        do {
            let ctx = try context(module: pos[0])
            let wanted = pos[1]
            guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == wanted || $0.name == wanted }) else {
                fail("no program named \(wanted)")
                return 2
            }
            let outcome = try await ctx.pipeline.run(program: program, options: runOptions)
            guard case .ran(_, let sceneText, _, _) = outcome else {
                fail("the program did not run: \(describe(outcome))")
                return 1
            }
            let assets = WebAssets.locate()
            var lastPrinted = -1
            let result = try await Exporter(assets: assets).export(
                sceneText: sceneText, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), options: options
            ) { p in
                let pct = p.total > 0 ? p.frame * 100 / p.total : 100
                if pct / 5 != lastPrinted {
                    lastPrinted = pct / 5
                    note(String(format: "export %3d%%  frame %d/%d  %.1f fps  eta %.0fs", pct, p.frame, p.total, p.framesPerSecond, p.eta))
                }
            }
            note(String(format: "exported %d frames to %@ in %.1fs (%.1f frames/s)", result.frames, result.url.path, result.elapsed, result.framesPerSecond))
            print("frames \(result.frames)")
            return 0
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    // MARK: --export file.gif

    /// `--export <module> <program> --out f.gif [--width 640] [--fps 20] [--rate 1] [--from ms] [--to ms] [--seed N] [--mode m]`.
    static func exportGIF(pos: [String], out: String, args: [String]) async -> Int32 {
        var options = GIFExportOptions()
        if let w = value(of: "--width", in: args) {
            guard let width = Int(w), GIFLimits.widths.contains(width) else { fail("--width must be one of \(GIFLimits.widths)"); return 2 }
            options.width = width
        }
        if let f = value(of: "--fps", in: args) {
            guard let fps = Int(f), GIFLimits.frameRates.contains(fps) else { fail("--fps for a GIF must be one of \(GIFLimits.frameRates)"); return 2 }
            options.fps = fps
        }
        if let r = value(of: "--rate", in: args) {
            guard let rate = Double(r), rate > 0 else { fail("--rate must be a positive number"); return 2 }
            options.rate = rate
        }
        if let f = value(of: "--from", in: args) {
            guard let from = Double(f), from >= 0 else { fail("--from must be a number of ms"); return 2 }
            options.from = from
        }
        if let t = value(of: "--to", in: args) {
            guard let to = Double(t), to >= 0 else { fail("--to must be a number of ms"); return 2 }
            options.to = to
        }
        var runOptions = RunOptions()
        if let m = value(of: "--mode", in: args) {
            guard let mode = RunOptions.Mode(rawValue: m) else { fail("--mode must be ordered or proportional"); return 2 }
            runOptions.mode = mode
        }
        if let s = value(of: "--seed", in: args) {
            guard let seed = UInt64(s) else { fail("--seed must be a number"); return 2 }
            runOptions.seed = seed
        }
        do {
            let ctx = try context(module: pos[0])
            let wanted = pos[1]
            guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == wanted || $0.name == wanted }) else {
                fail("no program named \(wanted)")
                return 2
            }
            let outcome = try await ctx.pipeline.run(program: program, options: runOptions)
            guard case .ran(_, let sceneText, _, _) = outcome else {
                fail("the program did not run: \(describe(outcome))")
                return 1
            }
            var lastPrinted = -1
            let result = try await Exporter(assets: WebAssets.locate()).exportGIF(
                sceneText: sceneText, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath), options: options
            ) { p in
                let pct = p.total > 0 ? p.frame * 100 / p.total : 100
                if pct / 25 != lastPrinted {
                    lastPrinted = pct / 25
                    note(String(format: "export %3d%%  frame %d/%d  %.1f fps", pct, p.frame, p.total, p.framesPerSecond))
                }
            }
            note(String(format: "exported %d frames (%dx%d, %d bytes) to %@ in %.1fs", result.frames, result.width, result.height, result.bytes, result.url.path, result.elapsed))
            print("frames \(result.frames)")
            return 0
        } catch {
            fail(error.friendlyText)
            return 1
        }
    }
}
