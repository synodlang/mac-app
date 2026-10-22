import AppKit
import Foundation
import SynodCore
import SynodWeb

/// `--stage-check <module> [--program raft] [--report f]`: headless regression checks for the
/// stage. (a) a loaded scene is drawn while paused; (b) with stopAtPause the player halts at the
/// first pause marker; (c) the Predict logic turns that halt into a question.
enum StageCheck {
    struct Result: Codable {
        var program: String
        var ok: Bool
        var failures: [String] = []
        var distinctColors = 0
        var nonBackground = 0.0
        var distinctColorsAfterSeek = 0
        var markerAt = 0.0
        var stoppedAt = 0.0
        var question: String?
    }

    /// Collects stage events for the whole run (the stream has one consumer).
    @MainActor final class Log {
        var events: [PlayerEvent] = []
    }

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--stage-check", in: args).first else {
            h.fail("usage: --stage-check <module> [--program raft] [--report file]")
            return 2
        }
        let wanted = h.value(of: "--program", in: args) ?? "raft"
        let ctx: HeadlessCommands.Context
        do { ctx = try h.context(module: modulePath) } catch { h.fail(error.localizedDescription); return 2 }
        guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == wanted || $0.name == wanted }) else {
            h.fail("no program named \(wanted)")
            return 2
        }
        let stage: StageController
        do {
            stage = try StageController(assets: WebAssets.locate(), size: CGSize(width: 960, height: 600), offscreenWindow: true)
            try await stage.waitUntilReady()
        } catch { h.fail("stage failed to start: \(error.localizedDescription)"); return 1 }
        let log = Log()
        let collector = Task { @MainActor in for await ev in stage.events { log.events.append(ev) } }

        var results: [Result] = []
        for mode in [RunOptions.Mode.proportional, .ordered] {
            var r = await check(program, mode: mode, ctx: ctx, stage: stage, log: log)
            r.program = "\(program.relPath) (\(mode.rawValue))"
            h.note("\(r.ok ? "ok  " : "FAIL") stage-check \(r.program)  colors \(r.distinctColors)  marker \(r.markerAt)  stopped \(r.stoppedAt)\(r.failures.isEmpty ? "" : "  " + r.failures.joined(separator: "; "))")
            results.append(r)
        }
        stage.tearDown()
        collector.cancel()
        let model = await modelCheck(modulePath: modulePath, program: wanted)
        h.note("\(model.ok ? "ok  " : "FAIL") stage-check model predict\(model.failures.isEmpty ? "" : "  " + model.failures.joined(separator: "; "))")
        results.append(model)
        let ok = results.allSatisfy(\.ok)
        if let path = h.value(of: "--report", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Report: Codable { var ok: Bool; var checks: [Result] }
            try? enc.encode(Report(ok: ok, checks: results)).write(to: URL(fileURLWithPath: path))
        }
        return ok ? 0 : 1
    }

    static let minColors = 4

    /// Drives the real WorkspaceModel (Predict toggle, mode change, play) on a temporary copy of
    /// the module and expects it to stop with a question at the first pause marker.
    @MainActor
    static func modelCheck(modulePath: String, program: String) async -> Result {
        var r = Result(program: "model predict", ok: false)
        func fail(_ m: String) { r.failures.append(m) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("synod-stage-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.copyItem(at: URL(fileURLWithPath: (modulePath as NSString).expandingTildeInPath), to: tmp)
            let ws = try Workspace.open(tmp)
            let model = WorkspaceModel(workspace: ws, recordRecent: false)
            defer { model.stop() }
            guard let stage = model.stage else { fail("no stage"); return r }
            // Host the view in a window like StageView does in the app.
            let win = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 960, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = stage.webView
            win.orderFrontRegardless()
            defer { win.close() }
            try await stage.waitUntilReady()
            guard let p = model.scan.programs.first(where: { $0.relPath == program || $0.name == program }) else {
                fail("no program \(program)"); return r
            }
            // The order a user follows: pick the program, turn Predict on, switch mode, play.
            model.select(.init(origin: .own, kind: .program, relPath: p.relPath))
            model.setPredict(true)
            model.setMode(.proportional)
            func waitLoaded() async throws {
                try await Task.sleep(for: .milliseconds(200))
                let end = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < end {
                    if let l = model.loaded, l.options.mode == .proportional, !model.coordinator.isRunning { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw HeadlessCommands.HeadlessError("run did not finish")
            }
            try await waitLoaded()
            guard let marker = model.loaded?.scene.markers.filter({ $0.kind == "pause" }).min(by: { $0.at < $1.at }) else {
                fail("no pause marker"); return r
            }
            r.markerAt = marker.at
            model.setSpeed(4)
            try await Task.sleep(for: .milliseconds(200))
            model.seek(to: 0)
            try await Task.sleep(for: .milliseconds(200))
            model.togglePlay()
            let end = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < end, model.predictQuestion == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            r.question = model.predictQuestion
            r.stoppedAt = stage.state.time
            if model.predictQuestion == nil { fail("no question; stage time \(stage.state.time), playing \(stage.state.playing)") }
            else if model.predictQuestion != marker.text { fail("wrong question") }
            if abs(stage.state.time - marker.at) > 50 { fail("stopped at \(stage.state.time), marker at \(marker.at)") }
            // Answer and continue: the answer file is written and playback resumes.
            if model.predictQuestion != nil {
                model.predictAnswer = "check"
                model.continuePredict()
                try await Task.sleep(for: .milliseconds(300))
                let store = AnswerStore(moduleRoot: ws.root, program: p.relPath)
                if store.entry(for: marker.text)?.answer != "check" { fail("answer was not saved") }
                try? fm.removeItem(at: store.fileURL)
                if !stage.state.playing { fail("not playing after Continue") }
            }
        } catch { fail(error.localizedDescription) }
        r.ok = r.failures.isEmpty
        return r
    }

    @MainActor
    static func check(_ program: Workspace.Program, mode: RunOptions.Mode, ctx: HeadlessCommands.Context,
                      stage: StageController, log: Log) async -> Result {
        var r = Result(program: program.relPath, ok: false)
        func fail(_ m: String) { r.failures.append(m) }
        do {
            let outcome = try await ctx.pipeline.run(program: program, options: RunOptions(mode: mode))
            guard case .ran(_, let sceneText, let scene, _) = outcome else { fail("did not run"); return r }

            // (a) drawn while paused, straight after load, with no play and no seek.
            try await stage.setScene(sceneText, keepTime: false)
            try await Task.sleep(for: .milliseconds(400))
            let loaded = try await stage.snapshotImage()
            r.distinctColors = loaded.distinctColorCount
            r.nonBackground = loaded.nonBackgroundFraction
            if r.distinctColors < minColors || r.nonBackground < 0.001 {
                fail("stage is blank after load (\(r.distinctColors) colours, \(r.nonBackground) non-background)")
            }
            // A re-run while paused (keepTime) and a seek must also leave a drawn frame.
            try await stage.setScene(sceneText, keepTime: true)
            try await stage.seek(to: scene.duration / 2)
            try await Task.sleep(for: .milliseconds(300))
            r.distinctColorsAfterSeek = try await stage.snapshotImage().distinctColorCount
            if r.distinctColorsAfterSeek < minColors { fail("stage is blank after re-run and seek") }

            // (b) stopAtPause halts at the first pause marker.
            guard let marker = scene.markers.filter({ $0.kind == "pause" }).min(by: { $0.at < $1.at }) else {
                fail("scene has no pause marker")
                return r
            }
            r.markerAt = marker.at
            try await stage.setScene(sceneText, keepTime: false)
            try await stage.setStopAtPause(true)
            try await stage.setRate(4)
            try await stage.seek(to: max(0, marker.at - 400))
            log.events.removeAll()
            try await stage.play()
            let deadline = ContinuousClock.now + .seconds(5)
            var halt: PlayerEvent?
            while ContinuousClock.now < deadline {
                halt = log.events.first { if case .pause = $0 { return true } else { return false } }
                if halt != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try await stage.setStopAtPause(false)
            try await stage.setRate(1)
            guard let halt else { fail("no pause event within 5 s (ran past the marker)"); return r }
            if halt != .pause(reason: .marker) { fail("paused with \(halt), expected marker") }
            let info = try await stage.stageInfo()
            r.stoppedAt = info.time
            if abs(info.time - marker.at) > 50 { fail("stopped at \(info.time), marker at \(marker.at)") }
            if info.playing { fail("still playing after the marker") }

            // (c) the model logic: the pause marker's text becomes the question.
            let seen = log.events.compactMap { ev -> PlayerEvent? in
                if case .marker(let k, _, _, _) = ev, k == "pause" { return ev } else { return nil }
            }
            if seen.isEmpty { fail("no pause marker event before the halt") }
            var predict = PredictLogic()
            var question: String?
            for ev in log.events { question = predict.handle(ev, predictEnabled: true) ?? question }
            r.question = question
            if question == nil { fail("predict logic produced no question") }
            else if question != marker.text { fail("question \(question ?? "") != marker text \(marker.text)") }
        } catch {
            fail(error.localizedDescription)
        }
        r.ok = r.failures.isEmpty
        return r
    }
}
