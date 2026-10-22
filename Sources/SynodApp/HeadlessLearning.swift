import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SynodCore
import SynodWeb

/// The headless checks of the learning modes (M9): `--predict-check`, `--hit-check`, `--breakit-check`,
/// `--compare-check` and `--gif-check`. Each runs under `NSApplication` `.prohibited` with a temporary
/// data folder, works on temporary copies of the module, and writes a JSON report with `--report`.
enum HeadlessLearning {
    struct Check: Codable {
        var name: String
        var ok = false
        var failures: [String] = []
        var metrics: [String: Double] = [:]
        var notes: [String] = []
    }

    struct Report: Codable {
        var ok: Bool
        var mode: String
        var checks: [Check]
    }

    /// Limits of the GIF frame check, calibrated on tcp, raft and cassandra (see `gifCheck`).
    enum Thresholds {
        /// Each sampled GIF frame against the stage frame at 640 px.
        static let gifMinPSNR = 30.0
        /// The lowest `gifMinPSNR` may ever be.
        static let gifPSNRFloor = 28.0
        /// "Closer to its own frame than to its neighbours' wherever the frames differ": only where two
        /// neighbouring stage frames are further apart than this (dB).
        static let distinctRefPSNR = 40.0
    }

    // MARK: Plumbing

    static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

    static func finish(mode: String, checks: [Check], args: [String]) -> Int32 {
        let h = HeadlessCommands.self
        for c in checks {
            let m = c.metrics.sorted { $0.key < $1.key }.map { "\($0.key) \(format($0.value))" }.joined(separator: "  ")
            h.note("\(c.ok ? "ok  " : "FAIL") \(mode) \(c.name)  \(m)\(c.failures.isEmpty ? "" : "  " + c.failures.joined(separator: "; "))")
            for n in c.notes { h.note("     \(n)") }
        }
        let report = Report(ok: !checks.isEmpty && checks.allSatisfy(\.ok), mode: mode, checks: checks)
        if let path = h.value(of: "--report", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(report).write(to: URL(fileURLWithPath: path))
        }
        return report.ok ? 0 : 1
    }

    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    /// A workspace model on a temporary copy of `module`, its stage hosted off screen like the app does.
    final class Rig {
        let model: WorkspaceModel
        let root: URL
        private let window: NSWindow
        private let scratch: URL

        @MainActor
        init(module: String, mutate: (URL) throws -> Void = { _ in }) throws {
            let fm = FileManager.default
            scratch = fm.temporaryDirectory.appendingPathComponent("synod-learning-\(UUID().uuidString)")
            root = scratch.appendingPathComponent("module")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: (module as NSString).expandingTildeInPath), to: root)
            try mutate(root)
            let ws = try Workspace.open(root)
            model = WorkspaceModel(workspace: ws, recordRecent: false)
            model.editor.undoGroupsByEvent = false
            guard let stage = model.stage else { throw HeadlessCommands.HeadlessError(model.stageError ?? "no stage") }
            window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 960, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = stage.webView
            window.orderFrontRegardless()
        }

        @MainActor
        func close() {
            model.stop()
            window.close()
            try? FileManager.default.removeItem(at: scratch)
        }

        @MainActor
        func select(_ program: Workspace.Program, timeout: Double = 30) async throws {
            guard let stage = model.stage else { throw HeadlessCommands.HeadlessError("no stage") }
            try await stage.waitUntilReady()
            let key = model.workspace.root.path + "|" + program.relPath
            model.select(.init(origin: .own, kind: .program, relPath: program.relPath))
            let ok = await HeadlessLearning.wait(timeout) {
                model.loaded?.programKey == key && !model.coordinator.isRunning && model.coordinator.generation > 0
            }
            if !ok { throw HeadlessCommands.HeadlessError("\(program.relPath) did not finish running") }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// A DOM click on the stage canvas at (x, y) CSS px, through `stage.js` like a mouse would.
    static func domClick(_ stage: StageController, x: Double, y: Double) async throws {
        _ = try await stage.webView.callAsyncJavaScript(
            """
            const c = document.querySelector('#stage canvas'); const r = c.getBoundingClientRect();
            const o = {clientX: r.left + x, clientY: r.top + y, button: 0, pointerId: 1, isPrimary: true, bubbles: true};
            c.dispatchEvent(new PointerEvent('pointerdown', o));
            c.dispatchEvent(new PointerEvent('pointerup', o));
            """, arguments: ["x": x, "y": y], in: nil, contentWorld: .page)
    }

    static func domDrag(_ stage: StageController, from: (Double, Double), to: (Double, Double)) async throws {
        _ = try await stage.webView.callAsyncJavaScript(
            """
            const c = document.querySelector('#stage canvas'); const r = c.getBoundingClientRect();
            const o = (p, t) => ({clientX: r.left + p[0], clientY: r.top + p[1], button: 0, pointerId: 2, isPrimary: true, bubbles: true});
            c.dispatchEvent(new PointerEvent('pointerdown', o(a)));
            c.dispatchEvent(new PointerEvent('pointermove', o(b)));
            c.dispatchEvent(new PointerEvent('pointerup', o(b)));
            """, arguments: ["a": [from.0, from.1], "b": [to.0, to.1]], in: nil, contentWorld: .page)
    }

    static func center(_ r: StageRect) -> (Double, Double) { (r.x + r.w / 2, r.y + r.h / 2) }

    /// Programs of the module, or the one named with `--program`.
    static func programs(in ws: Workspace, args: [String]) -> [Workspace.Program] {
        let all = ws.scan().programs
        guard let wanted = HeadlessCommands.value(of: "--program", in: args) else { return all }
        return all.filter { $0.relPath == wanted || $0.name == wanted }
    }

    // MARK: --predict-check

    /// `--predict-check <module> [--program p] [--report f]`: every program's scene has pause markers with 2
    /// to 6 choices; playing with Predict on stops at each one with its choices in the model; choosing
    /// index 0 saves the answer with its choice and choices; playback goes on to the end.
    static func predictCheck(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let module = h.positionals(after: "--predict-check", in: args).first else {
            h.fail("usage: --predict-check <module> [--program name] [--report file]")
            return 2
        }
        var checks: [Check] = []
        do {
            let rig = try Rig(module: module)
            defer { rig.close() }
            let model = rig.model
            model.setPredict(true)
            for program in programs(in: model.workspace, args: args) {
                checks.append(await predictOne(rig, program))
            }
        } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        return finish(mode: "predict-check", checks: checks, args: args)
    }

    static func predictOne(_ rig: Rig, _ program: Workspace.Program) async -> Check {
        var c = Check(name: program.relPath)
        func fail(_ m: String) { c.failures.append(m) }
        let model = rig.model
        do {
            try await rig.select(program)
            guard let run = model.loaded, let stage = model.stage else { fail("not loaded"); return c }
            let markers = run.scene.markers.filter { $0.kind == "pause" }.sorted { $0.at < $1.at }
            c.metrics["pauseMarkers"] = Double(markers.count)
            if markers.isEmpty { fail("no pause marker"); return c }
            for m in markers where !(2...6).contains(m.choices.count) { fail("marker at \(m.at) has \(m.choices.count) choices") }
            if !c.failures.isEmpty { return c }
            model.setSpeed(4)
            try await Task.sleep(for: .milliseconds(150))
            let store = AnswerStore(moduleRoot: model.workspace.root, program: program.relPath)
            for marker in markers {
                try await stage.pause()
                try await stage.seek(to: max(0, marker.at - 400))
                try await Task.sleep(for: .milliseconds(150))
                model.togglePlay()
                let asked = await wait(10) { model.predictQuestion != nil }
                if !asked { fail("no question at \(marker.at) (stage time \(Int(stage.state.time)))"); break }
                if model.predictQuestion != marker.text { fail("question \(model.predictQuestion ?? "-") != marker text") }
                if model.predictChoices != marker.choices { fail("choices \(model.predictChoices) != marker \(marker.choices)") }
                if abs(stage.state.time - marker.at) > 50 { fail("stopped at \(stage.state.time), marker at \(marker.at)") }
                if stage.state.playing { fail("still playing at the question") }
                model.choosePredict(0)
                if model.predictQuestion != nil { fail("the panel stayed after choosing") }
                guard let saved = store.entry(for: marker.text) else { fail("answer not saved"); break }
                if saved.answer != marker.choices[0] || saved.choice != 0 || saved.choices != marker.choices {
                    fail("saved \(saved.answer) / \(String(describing: saved.choice)) / \(String(describing: saved.choices))")
                }
                if !(await wait(3) { stage.state.playing }) { fail("not playing after the answer") }
            }
            // Playback reaches the end from here: jump near it and let it play out.
            try await stage.pause()
            try await stage.seek(to: max(0, run.scene.duration - 300))
            try await Task.sleep(for: .milliseconds(100))
            model.togglePlay()
            let ended = await wait(10) { !stage.state.playing && stage.state.time >= run.scene.duration - 50 }
            if !ended { fail("playback did not reach the end (time \(Int(stage.state.time)) of \(Int(run.scene.duration)))") }
            if model.predictQuestion != nil { fail("a question appeared after the last marker") }
            try? FileManager.default.removeItem(at: store.fileURL)
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: --hit-check

    /// `--hit-check <module> [--program p] [--report f]`: at 10 times of each program, `hitTest` at the
    /// center of every `nodeBounds` box returns that node (or a message dot, which is skipped); at least
    /// 80% node hits and no mismatch. Then DOM clicks through `stage.js` select a node, a message and
    /// a dragged box in the workspace model.
    static func hitCheck(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let module = h.positionals(after: "--hit-check", in: args).first else {
            h.fail("usage: --hit-check <module> [--program name] [--report file]")
            return 2
        }
        var checks: [Check] = []
        do {
            let rig = try Rig(module: module)
            defer { rig.close() }
            var firstMessage: (program: Workspace.Program, at: Double, x: Double, y: Double, msg: Int)?
            for program in programs(in: rig.model.workspace, args: args) {
                let (c, msgHit) = await hitSamples(rig, program)
                checks.append(c)
                if firstMessage == nil, let m = msgHit { firstMessage = (program, m.at, m.x, m.y, m.msg) }
            }
            if let raft = rig.model.workspace.scan().programs.first(where: { $0.name == "raft" }) ?? rig.model.workspace.scan().programs.first {
                checks.append(await domClicks(rig, raft, message: firstMessage))
            }
        } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        return finish(mode: "hit-check", checks: checks, args: args)
    }

    static func hitSamples(_ rig: Rig, _ program: Workspace.Program) async -> (Check, (at: Double, x: Double, y: Double, msg: Int)?) {
        var c = Check(name: program.relPath)
        func fail(_ m: String) { if c.failures.count < 6 { c.failures.append(m) } }
        var total = 0, nodeHits = 0, msgHits = 0, mismatches = 0
        var msgHit: (at: Double, x: Double, y: Double, msg: Int)?
        do {
            try await rig.select(program)
            guard let stage = rig.model.stage, let run = rig.model.loaded else { fail("not loaded"); return (c, nil) }
            try await stage.pause()
            for k in 0..<10 {
                let at = run.scene.duration * (Double(k) + 0.5) / 10
                try await stage.seek(to: at)
                try await Task.sleep(for: .milliseconds(40))
                let boxes = try await stage.nodeBounds()
                for b in boxes {
                    let (x, y) = center(b.rect)
                    total += 1
                    let hit = try await stage.hitTest(x: x, y: y)
                    if let hit, let msg = hit.msg {
                        msgHits += 1
                        if msgHit == nil { msgHit = (at, x, y, msg) }
                    } else if hit?.node == b.node {
                        nodeHits += 1
                    } else {
                        mismatches += 1
                        fail("t \(Int(at)) ms: \(b.node) box center hit \(hit?.node ?? "nothing")")
                    }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
        c.metrics["samples"] = Double(total)
        c.metrics["nodeHits"] = Double(nodeHits)
        c.metrics["messageHits"] = Double(msgHits)
        c.metrics["mismatches"] = Double(mismatches)
        // A message dot over a node's center is a message hit and is skipped; the rest must be node hits.
        let counted = total - msgHits
        let ratio = counted > 0 ? Double(nodeHits) / Double(counted) : 0
        c.metrics["nodeHitRatio"] = (ratio * 100).rounded() / 100
        if total == 0 { fail("no node boxes") }
        if nodeHits < 3 { fail("only \(nodeHits) node hits") }
        if ratio < 0.8 { fail("only \(Int(ratio * 100))% node hits among \(total - msgHits) samples") }
        if mismatches > 0 { fail("\(mismatches) mismatches") }
        c.ok = c.failures.isEmpty
        return (c, msgHit)
    }

    static func domClicks(_ rig: Rig, _ program: Workspace.Program,
                          message: (program: Workspace.Program, at: Double, x: Double, y: Double, msg: Int)?) async -> Check {
        var c = Check(name: "DOM clicks select in the model (\(program.relPath))")
        func fail(_ m: String) { c.failures.append(m) }
        let model = rig.model
        do {
            try await rig.select(program)
            guard let stage = model.stage, let run = model.loaded else { fail("not loaded"); return c }
            try await stage.pause()
            try await stage.seek(to: run.scene.duration * 0.5)
            try await Task.sleep(for: .milliseconds(80))
            let boxes = try await stage.nodeBounds()
            // A click on a node box center that hits that node (a flight can sit on top at some times).
            var picked: (node: String, x: Double, y: Double)?
            for b in boxes.reversed() where b.node != model.selectedNode {
                let (x, y) = center(b.rect)
                if let hit = try await stage.hitTest(x: x, y: y), hit.node == b.node, hit.msg == nil { picked = (b.node, x, y); break }
            }
            guard let p = picked else { fail("no node box with a clean center hit"); return c }
            try await domClick(stage, x: p.x, y: p.y)
            let selected = await wait(3) { model.selectedNode == p.node && model.outlinedNode == p.node }
            if !selected { fail("clicking \(p.node) selected \(model.selectedNode ?? "nothing")") }
            c.metrics["nodeSelected"] = selected ? 1 : 0

            // A dragged box over two nodes sets the partition side (box center inside).
            let two = boxes.prefix(2)
            if two.count == 2 {
                let xs = two.flatMap { [$0.rect.x - 3, $0.rect.x + $0.rect.w + 3] }
                let ys = two.flatMap { [$0.rect.y - 3, $0.rect.y + $0.rect.h + 3] }
                try await domDrag(stage, from: (xs.min()!, ys.min()!), to: (xs.max()!, ys.max()!))
                let boxed = await wait(3) { !model.boxNodes.isEmpty }
                let expect = Set(BreakItSelection.nodes(inBox: StageRect(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!), boxes: boxes))
                if !boxed || Set(model.boxNodes) != expect { fail("drag selected \(model.boxNodes), expected \(expect.sorted())") }
                c.metrics["boxNodes"] = Double(model.boxNodes.count)
            }

            // A click on a message dot selects the message and jumps to its send.
            if let m = message {
                if m.program.relPath != program.relPath { try await rig.select(m.program) }
                guard let run = model.loaded, let stage = model.stage else { fail("not loaded"); return c }
                try await stage.pause()
                try await stage.seek(to: m.at)
                try await Task.sleep(for: .milliseconds(80))
                try await domClick(stage, x: m.x, y: m.y)
                let got = await wait(3) { model.selectedMessage == m.msg }
                if !got { fail("clicking message dot \(m.msg) selected \(String(describing: model.selectedMessage))") }
                if let seq = model.sendSeq(ofMessage: m.msg), let at = run.trace.timeOfSeq(seq) {
                    let jumped = await wait(3) { abs(stage.state.time - at) < 5 }
                    if !jumped { fail("did not jump to the send of message \(m.msg) (time \(stage.state.time), send \(at))") }
                } else { fail("no net.Sent for message \(m.msg)") }
                c.metrics["messageSelected"] = got ? 1 : 0
            } else {
                c.notes.append("no message dot was hit at a node center; message click not tested")
            }
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: --breakit-check

    struct BreakItScript: Decodable {
        struct Replace: Decodable { var file: String; var with: String }
        struct Step: Decodable {
            var seekLastFactAtOrBefore: String
            var clickNode: String
            var offers: String
            var action: String
            /// The time typed in the sheet's time field; nil keeps the default (the first whole ms after the fact).
            var time: String?
        }
        struct Expect: Decodable {
            var node: String
            var crashWindowSeconds: [Double]
            var hintsNode: String
            var hintsField: String
            var hintsAfterSeconds: Double
            var mutationType: String
            var dataField: String
            var dataContains: [String]
            var insertedBlocks: [String]
        }
        var program: String
        var replace: Replace?
        var steps: [Step]
        var expect: Expect
    }

    /// `--breakit-check <module> --script file.json [--report f]`: the Cassandra hinted-handoff lesson by
    /// clicks alone (a Crash and a Restart of n5), on a temporary copy.
    static func breakItCheck(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let module = h.positionals(after: "--breakit-check", in: args).first, let scriptPath = h.value(of: "--script", in: args) else {
            h.fail("usage: --breakit-check <module> --script file.json [--report file]")
            return 2
        }
        let scriptURL = URL(fileURLWithPath: (scriptPath as NSString).expandingTildeInPath)
        let script: BreakItScript
        do { script = try JSONDecoder().decode(BreakItScript.self, from: Data(contentsOf: scriptURL)) } catch {
            h.fail("cannot read the script: \(error.localizedDescription)")
            return 2
        }
        var checks: [Check] = []
        do {
            let rig = try Rig(module: module) { root in
                if let r = script.replace {
                    let src = scriptURL.deletingLastPathComponent().appendingPathComponent(r.with)
                    let dest = root.appendingPathComponent(r.file)
                    try FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: src, to: dest)
                }
            }
            defer { rig.close() }
            checks.append(await breakItFlow(rig, script))
        } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        return finish(mode: "breakit-check", checks: checks, args: args)
    }

    static func lastMappedFact(in run: LoadedRun, atOrBefore micros: Int64) -> (seq: Int, at: Double, t: Int64)? {
        for e in run.trace.events.reversed() where e.t <= micros {
            if let at = run.trace.timeOfSeq(e.seq) { return (e.seq, at, e.t) }
        }
        return nil
    }

    static func number(_ v: SynodValue) -> Double? { if case .number(let d) = v { return d } else { return nil } }

    static func breakItFlow(_ rig: Rig, _ script: BreakItScript) async -> Check {
        var c = Check(name: "\(script.program) hinted handoff by clicks")
        func fail(_ m: String) { c.failures.append(m) }
        let model = rig.model
        do {
            guard let program = model.workspace.scan().programs.first(where: { $0.name == script.program || $0.relPath == script.program }) else {
                fail("no program \(script.program)"); return c
            }
            let mainFile = program.relPath == "." ? program.mainFile : program.relPath + "/" + program.mainFile
            let fileURL = model.workspace.url(forRelative: mainFile)
            let calm = try String(contentsOf: fileURL, encoding: .utf8)
            let afterBlocksBefore = calm.components(separatedBy: "\n").filter { $0.hasPrefix("  after ") }.count
            try await rig.select(program)
            guard let stage = model.stage else { fail("no stage"); return c }

            for (i, step) in script.steps.enumerated() {
                guard let run = model.loaded else { fail("step \(i + 1): no run"); return c }
                guard let limit = FormatTime.parse(step.seekLastFactAtOrBefore), let fact = lastMappedFact(in: run, atOrBefore: limit) else {
                    fail("step \(i + 1): no fact at or before \(step.seekLastFactAtOrBefore)"); return c
                }
                try await stage.pause()
                try await stage.seek(to: fact.at)
                if !(await wait(3) { abs(stage.state.time - fact.at) < 1 }) { fail("step \(i + 1): the stage did not reach \(fact.at)") }
                try await Task.sleep(for: .milliseconds(100))
                // Click the node on the stage: the first point of its box that hits it.
                let boxes = try await stage.nodeBounds()
                guard let box = boxes.first(where: { $0.node == step.clickNode }) else { fail("step \(i + 1): no box for \(step.clickNode)"); return c }
                var points = [center(box.rect)]
                for fx in [0.5, 0.25, 0.75] { for fy in [0.25, 0.75, 0.5] { points.append((box.rect.x + box.rect.w * fx, box.rect.y + box.rect.h * fy)) } }
                var clickAt: (Double, Double)?
                for p in points {
                    if let hit = try await stage.hitTest(x: p.0, y: p.1), hit.node == step.clickNode, hit.msg == nil { clickAt = p; break }
                }
                guard let at = clickAt else { fail("step \(i + 1): no clean hit on \(step.clickNode)"); return c }
                if model.selectedNode == step.clickNode { model.selectedNode = model.loaded?.trace.nodes.first { $0 != step.clickNode } }
                try await domClick(stage, x: at.0, y: at.1)
                if !(await wait(3) { model.selectedNode == step.clickNode }) { fail("step \(i + 1): the click did not select \(step.clickNode)"); return c }

                let offer = model.breakIt.nodeOffer(step.clickNode)
                if (step.offers == "crash" && offer != .crash) || (step.offers == "restart" && offer != .restart) {
                    fail("step \(i + 1): \(step.clickNode) offers \(offer), expected \(step.offers)"); return c
                }
                if case .unavailable(let why) = model.breakIt.availability { fail("step \(i + 1): Break it unavailable: \(why)"); return c }
                let action: BreakItAction = step.action == "crash" ? .crash(node: step.clickNode) : .restart(node: step.clickNode)
                model.breakIt.begin(action)
                guard var sheet = model.breakIt.sheet else { fail("step \(i + 1): no sheet"); return c }
                if let t = step.time {
                    model.breakIt.setTimeText(t)
                    guard let edited = model.breakIt.sheet, edited.error == nil, edited.plan.time == FormatTime.parse(t) else {
                        fail("step \(i + 1): the time \(t) was not accepted: \(model.breakIt.sheet?.error ?? "-")"); return c
                    }
                    sheet = edited
                }
                c.notes.append("step \(i + 1): fact t=\(SimTime(microseconds: fact.t)) -> \(sheet.plan.blockLines.joined(separator: " / ").replacingOccurrences(of: "  ", with: " "))")
                c.metrics["step\(i + 1)T_ms"] = Double(sheet.plan.time) / 1000
                await model.breakIt.apply()
                if case .applied = model.breakIt.outcome {} else { fail("step \(i + 1): outcome \(String(describing: model.breakIt.outcome))"); return c }
                if !(await wait(5) { !model.coordinator.isRunning }) { fail("step \(i + 1): still running") }
                try await Task.sleep(for: .milliseconds(300))
            }

            // The source: exactly the inserted blocks, none typed.
            let after = try String(contentsOf: fileURL, encoding: .utf8)
            let inserted = after.components(separatedBy: "\n").filter { $0.hasPrefix("  after ") }.count - afterBlocksBefore
            if inserted != script.steps.count { fail("\(inserted) inserted blocks, expected \(script.steps.count)") }
            for b in script.expect.insertedBlocks where after.components(separatedBy: b).count != 2 { fail("source lacks exactly one `\(b)`") }

            // The trace.
            guard let run = model.loaded else { fail("no final run"); return c }
            let ex = script.expect
            let events = run.trace.events
            let crash = events.first { $0.ev == "sim.Crashed" && $0.node == ex.node }
            let restart = events.first { e in if case .restarted = e.payload { return e.node == ex.node && e.t > (crash?.t ?? 0) } else { return false } }
            func change(_ node: String, after t: Int64, where pred: (Double) -> Bool) -> TraceEvent? {
                events.first { e in
                    if case .changed(let f, _, let new) = e.payload, f == ex.hintsField, e.node == node, e.t >= t, let n = number(new) { return pred(n) }
                    return false
                }
            }
            let hint = change(ex.hintsNode, after: Int64(ex.hintsAfterSeconds * 1_000_000)) { $0 >= 1 }
            let arrival = events.first { e in
                if case .arrived(let env) = e.payload { return env.msg.type == ex.mutationType && env.to == ex.node && e.t > (restart?.t ?? .max) }
                return false
            }
            let zero = change(ex.hintsNode, after: hint?.t ?? .max) { $0 == 0 }
            if let t = crash?.t {
                c.metrics["crashT_s"] = Double(t) / 1e6
                if Double(t) / 1e6 < ex.crashWindowSeconds[0] || Double(t) / 1e6 > ex.crashWindowSeconds[1] { fail("sim.Crashed at \(SimTime(microseconds: t)), expected \(ex.crashWindowSeconds)") }
            } else { fail("no sim.Crashed \(ex.node)") }
            if let t = hint?.t { c.metrics["hint_s"] = Double(t) / 1e6 } else { fail("\(ex.hintsNode) \(ex.hintsField) never rose to 1 after \(ex.hintsAfterSeconds) s") }
            if let t = restart?.t { c.metrics["restartT_s"] = Double(t) / 1e6 } else { fail("no sim.Restarted \(ex.node)") }
            if let t = arrival?.t { c.metrics["arrival_s"] = Double(t) / 1e6 } else { fail("no \(ex.mutationType) arrival at \(ex.node) after the restart") }
            if let t = zero?.t { c.metrics["hintsZero_s"] = Double(t) / 1e6 } else { fail("\(ex.hintsField) never went back to 0") }
            if let a = crash?.seq, let b = hint?.seq, let r = restart?.seq, let ar = arrival?.seq {
                if !(a < b && b < r && r < ar) { fail("facts out of order: crash \(a), hints \(b), restart \(r), arrival \(ar)") }
            }
            if let last = events.last?.seq, let data = run.trace.state(of: ex.node, atSeq: last)?.value(of: ex.dataField) {
                let d = data.display
                for s in ex.dataContains where !d.contains(s) { fail("\(ex.node) \(ex.dataField) is \(d), lacks \(s)") }
            } else { fail("no final state of \(ex.node)") }
            if model.breakIt.before == nil { fail("the earlier run was not kept for Compare with before") }
            c.metrics["newlyBroken"] = Double(model.breakIt.broken.count)

            // Undo restores the text before the last change (the Restart), saved.
            await model.breakIt.undo()
            let undone = try String(contentsOf: fileURL, encoding: .utf8)
            if let restartBlock = ex.insertedBlocks.last, undone.contains(restartBlock) { fail("undo left the last block") }
            if let crashBlock = ex.insertedBlocks.first, !undone.contains(crashBlock) { fail("undo removed the first block too") }
            if model.breakIt.outcome != nil { fail("the banner stayed after undo") }
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: --compare-check

    /// `--compare-check <module> <program> [--seeds 3,4] [--mode ordered|proportional] [--report f]`.
    static func compareCheck(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        let pos = h.positionals(after: "--compare-check", in: args)
        guard pos.count >= 2 else {
            h.fail("usage: --compare-check <module> <program> [--seeds 3,4] [--mode m] [--report file]")
            return 2
        }
        let seeds = (h.value(of: "--seeds", in: args) ?? "3,4").split(separator: ",").compactMap { UInt64($0) }
        guard seeds.count == 2 else { h.fail("--seeds needs two numbers"); return 2 }
        let mode = RunOptions.Mode(rawValue: h.value(of: "--mode", in: args) ?? "ordered") ?? .ordered
        var checks: [Check] = []
        do {
            let ctx = try h.context(module: pos[0])
            guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == pos[1] || $0.name == pos[1] }) else {
                h.fail("no program named \(pos[1])")
                return 2
            }
            checks.append(await compareOne(ctx, program, seeds: seeds, mode: mode))
        } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        return finish(mode: "compare-check", checks: checks, args: args)
    }

    @MainActor final class TimeLog { var events: [(times: CompareTimes, wall: Double)] = [] }

    static func compareOne(_ ctx: HeadlessCommands.Context, _ program: Workspace.Program, seeds: [UInt64], mode: RunOptions.Mode) async -> Check {
        var c = Check(name: "\(program.name) seeds \(seeds.map(String.init).joined(separator: " vs "))")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        var controller: CompareController?
        do {
            var runs: [LoadedRun] = []
            for seed in seeds {
                let opts = RunOptions(mode: mode, seed: seed)
                guard case .ran(let status, let sceneText, let scene, let trace) = try await ctx.pipeline.run(program: program, options: opts) else {
                    fail("seed \(seed) did not run"); return c
                }
                runs.append(LoadedRun(programKey: "k\(seed)", sceneText: sceneText, scene: scene, trace: trace, status: status, options: opts))
            }
            let (l, r) = (runs[0], runs[1])
            let lm = SyncMap(index: l.trace, duration: l.scene.duration)
            let rm = SyncMap(index: r.trace, duration: r.scene.duration)
            for (name, m) in [("left", lm), ("right", rm)] {
                for (a, b) in zip(m.knots, m.knots.dropFirst()) where !(a.t < b.t && a.at <= b.at) { fail("\(name) sync map is not monotone at t=\(a.t)"); break }
            }
            c.metrics["knotsLeft"] = Double(lm.knots.count)
            c.metrics["knotsRight"] = Double(rm.knots.count)

            let cc = try CompareController(assets: WebAssets.locate(), size: CGSize(width: 800, height: 400), offscreenWindow: false)
            controller = cc
            // An almost transparent window on screen keeps WebKit from treating the page as hidden (which
            // throttles it to a few frames a second); it takes no clicks and is closed at the end.
            let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.alphaValue = 0.01
            host.ignoresMouseEvents = true
            host.level = .normal
            host.contentView = cc.webView
            host.orderFrontRegardless()
            defer { host.close() }
            let log = TimeLog()
            let collector = Task { @MainActor in
                for await ev in cc.events { if case .time(let t) = ev { log.events.append((t, ProcessInfo.processInfo.systemUptime)) } }
            }
            defer { collector.cancel() }
            try await cc.waitUntilReady()
            let info = try await cc.setScenes(left: l.sceneText, right: r.sceneText,
                                              knotsLeft: CompareModel.knots(lm), knotsRight: CompareModel.knots(rm))
            if let w = (info.warningsLeft + info.warningsRight).first { fail("player warning: \(w)") }

            // The node lists match by name, in the model and on both stages.
            let pairs = CompareLogic.pairs(left: l.trace.nodes, right: r.trace.nodes)
            if !pairs.allSatisfy(\.isMatched) { fail("unmatched nodes: \(pairs.filter { !$0.isMatched }.map(\.name))") }
            c.metrics["nodes"] = Double(pairs.count)
            try await cc.pause()
            try await cc.seekSim(Double(lm.endTime) / 2)
            try await Task.sleep(for: .milliseconds(80))
            let leftNames = Set(try await cc.nodeBounds(side: .left).map(\.node))
            let rightBoxes = try await cc.nodeBounds(side: .right)
            if leftNames != Set(rightBoxes.map(\.node)) { fail("stage nodes differ: left \(leftNames.sorted()), right \(Set(rightBoxes.map(\.node)).sorted())") }
            // Selection by name works on both sides: the same node is hit at its box center.
            var hitBoth = 0
            for b in try await cc.nodeBounds(side: .left).prefix(3) {
                let (x, y) = center(b.rect)
                if let rb = rightBoxes.first(where: { $0.node == b.node }),
                   try await cc.hitTest(side: .left, x: x, y: y)?.node == b.node,
                   try await cc.hitTest(side: .right, x: center(rb.rect).0, y: center(rb.rect).1)?.node == b.node { hitBoth += 1 }
            }
            c.metrics["hitBothSides"] = Double(hitBoth)
            if hitBoth == 0 { fail("no node was hit on both sides at its box center") }
            if let n = leftNames.sorted().first { try await cc.setSelection(n); try await cc.setSelection(nil) }

            // 20 sample times: after seekSim(T) each player is at its own map's value.
            var worstLeft = 0.0, worstRight = 0.0
            let domain = Double(lm.endTime)
            for k in 0..<20 {
                let T = domain * Double(k) / 19
                try await cc.seekSim(T)
                try await Task.sleep(for: .milliseconds(30))
                let t = try await cc.times()
                let wantL = lm.at(simTime: T)
                let wantR = rm.counterpart(ofLeftTime: t.atLeft, left: lm)
                worstLeft = max(worstLeft, abs(t.atLeft - wantL))
                worstRight = max(worstRight, abs(t.atRight - wantR))
                if abs(t.atLeft - wantL) > 0.5 { fail("T=\(Int(T)): left at \(t.atLeft), map says \(wantL)") }
                if abs(t.atRight - wantR) > 0.5 { fail("T=\(Int(T)): right at \(t.atRight), map says \(wantR)") }
            }
            c.metrics["worstLeftMs"] = (worstLeft * 1000).rounded() / 1000
            c.metrics["worstRightMs"] = (worstRight * 1000).rounded() / 1000

            // Playing 2 s at 1x: the left pace is real time and the right side follows within a frame.
            try await cc.pause()
            try await cc.seekSim(0)
            try await cc.setRate(1)
            try await Task.sleep(for: .milliseconds(100))
            log.events.removeAll()
            let at0 = try await cc.times().atLeft
            try await cc.play()
            let wallPlay = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(2))
            let wallPause = ProcessInfo.processInfo.systemUptime
            try await cc.pause()
            try await Task.sleep(for: .milliseconds(100))
            // A hidden page draws only a few frames a second, so time events are scarce and the
            // player's time between frames is stale; a pause reads the clock exactly, so the pace is the
            // time that passed on the left player between play and pause over the wall time.
            let atEnd = try await cc.times().atLeft
            let played = log.events.filter { $0.times.atLeft > 0 }
            c.metrics["timeEvents"] = Double(played.count)
            if played.count < 2 { fail("only \(played.count) time events while playing") }
            let pace = (atEnd - at0) / 1000 / (wallPause - wallPlay)
            c.metrics["pace"] = (pace * 1000).rounded() / 1000
            if !HeadlessCommands.paceRange.contains(pace) { fail("left pace \(pace) outside 0.9...1.1") }
            var worstFollow = 0.0
            for e in played {
                let want = rm.counterpart(ofLeftTime: e.times.atLeft, left: lm)
                worstFollow = max(worstFollow, abs(e.times.atRight - want))
            }
            c.metrics["worstFollowMs"] = (worstFollow * 100).rounded() / 100
            if worstFollow > 17 { fail("the right side was \(worstFollow) ms from its map value") }
            if let lastError = cc.state.lastError { fail("page error: \(lastError)") }
        } catch {
            fail(error.localizedDescription)
        }
        controller?.tearDown()
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: --gif-check

    struct DecodedGIF {
        var frames: [[UInt8]] = []      // RGB, 3 bytes per pixel
        var delays: [Double] = []
        var loopCount: Int?
        var width = 0
        var height = 0
    }

    static func decodeGIF(_ url: URL) throws -> DecodedGIF {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw HeadlessCommands.HeadlessError("cannot read \(url.path)") }
        var d = DecodedGIF()
        if let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
           let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            d.loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int
        }
        for i in 0..<CGImageSourceGetCount(src) {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw HeadlessCommands.HeadlessError("cannot decode frame \(i)") }
            d.width = image.width
            d.height = image.height
            var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
            rgba.withUnsafeMutableBytes { raw in
                let ctx = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var rgb = [UInt8]()
            rgb.reserveCapacity(rgba.count / 4 * 3)
            for p in 0..<(rgba.count / 4) { rgb.append(contentsOf: [rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2]]) }
            d.frames.append(rgb)
            let fp = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let g = fp?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            d.delays.append((g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1)
        }
        return d
    }

    /// `--gif-check <file.gif> --module <module> --program <p> [--width 640] [--fps 20] [--rate 1]
    /// [--seed N] [--mode m] [--report f]`: the GIF has the planned frame count, delay, loop count and
    /// size, only palette colors, sampled frames close to the stage's own frames, and exporting again
    /// gives the same bytes. The file is exported first when missing.
    static func gifCheck(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let gifPath = h.positionals(after: "--gif-check", in: args).first, let programName = h.value(of: "--program", in: args) else {
            h.fail("usage: --gif-check <file.gif> --module <module> --program <name> [--width 640] [--fps 20] [--rate 1] [--samples 30] [--report file]")
            return 2
        }
        precondition(Thresholds.gifMinPSNR >= Thresholds.gifPSNRFloor, "GIF PSNR threshold below the floor")
        var options = GIFExportOptions()
        if let w = h.value(of: "--width", in: args).flatMap(Int.init) { options.width = w }
        if let f = h.value(of: "--fps", in: args).flatMap(Int.init) { options.fps = f }
        if let r = h.value(of: "--rate", in: args).flatMap(Double.init) { options.rate = r }
        var runOptions = RunOptions()
        if let m = h.value(of: "--mode", in: args).flatMap(RunOptions.Mode.init(rawValue:)) { runOptions.mode = m }
        if let s = h.value(of: "--seed", in: args).flatMap(UInt64.init) { runOptions.seed = s }
        let module = h.value(of: "--module", in: args) ?? AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"])?.examples?.path
        guard let module else { h.fail("--module is needed"); return 2 }
        let gifURL = URL(fileURLWithPath: (gifPath as NSString).expandingTildeInPath)
        var c = Check(name: "\(programName) \(gifURL.lastPathComponent)")
        func fail(_ m: String) { if c.failures.count < 10 { c.failures.append(m) } }
        do {
            let ctx = try h.context(module: module)
            guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == programName || $0.name == programName }) else {
                h.fail("no program named \(programName)")
                return 2
            }
            guard case .ran(_, let sceneText, let scene, _) = try await ctx.pipeline.run(program: program, options: runOptions) else {
                h.fail("the program did not run")
                return 1
            }
            let layout = try Exporter.gifLayout(sceneText: sceneText, duration: scene.duration, options: options)
            let plan = layout.plan
            let exporter = Exporter(assets: WebAssets.locate())
            if !FileManager.default.fileExists(atPath: gifURL.path) {
                _ = try await exporter.exportGIF(sceneText: sceneText, to: gifURL, options: options)
            }

            // The container.
            let d = try decodeGIF(gifURL)
            c.metrics["frames"] = Double(d.frames.count)
            c.metrics["expectedFrames"] = Double(plan.frameCount)
            c.metrics["width"] = Double(d.width)
            c.metrics["height"] = Double(d.height)
            c.metrics["bytes"] = Double((try? FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0)
            if d.frames.count != plan.frameCount { fail("\(d.frames.count) frames, planned \(plan.frameCount)") }
            if d.width != layout.width || d.height != layout.height { fail("size \(d.width)x\(d.height), planned \(layout.width)x\(layout.height)") }
            let wantDelay = Double(GIFLimits.delay(fps: options.fps)) / 100
            if let bad = d.delays.firstIndex(where: { abs($0 - wantDelay) > 1e-9 }) { fail("frame \(bad) delay \(d.delays[bad]), expected \(wantDelay)") }
            if d.loopCount != 0 { fail("loop count \(String(describing: d.loopCount)), expected 0 (forever)") }

            // Only palette colors.
            let palette = GIFPalette(sceneText: sceneText)
            let allowed = Set(palette.colors.map { UInt32($0.r) << 16 | UInt32($0.g) << 8 | UInt32($0.b) })
            var seen = Set<UInt32>()
            var outside = 0
            for f in d.frames {
                var i = 0
                while i < f.count {
                    let v = UInt32(f[i]) << 16 | UInt32(f[i + 1]) << 8 | UInt32(f[i + 2])
                    if seen.insert(v).inserted, !allowed.contains(v) { outside += 1 }
                    i += 3
                }
            }
            c.metrics["distinctColors"] = Double(seen.count)
            if outside > 0 { fail("\(outside) colors are not in the palette") }

            // Exporting again gives the same bytes.
            let again = FileManager.default.temporaryDirectory.appendingPathComponent("synod-gif-\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: again) }
            _ = try await exporter.exportGIF(sceneText: sceneText, to: again, options: options)
            if try Data(contentsOf: again) != Data(contentsOf: gifURL) { fail("a second export differs from the file") }

            // Sampled frames against the stage's frames at the same size.
            let stage = try StageController(assets: WebAssets.locate(), size: CGSize(width: layout.width, height: layout.height), offscreenWindow: true)
            defer { stage.tearDown() }
            try await stage.waitUntilReady()
            try await stage.setScene(sceneText, keepTime: false)
            var cache: [Int: BGRAImage] = [:]
            func reference(_ k: Int) async throws -> BGRAImage {
                if let r = cache[k] { return r }
                let png = try await stage.renderFramePNG(at: plan.at(k), width: layout.width, height: layout.height, pixelRatio: 1)
                let img = try PixelBuffers.decodePNG(png)
                cache[k] = img
                return img
            }
            func gifFrame(_ k: Int) -> BGRAImage {
                var bgra = [UInt8](repeating: 255, count: d.width * d.height * 4)
                let f = d.frames[k]
                for p in 0..<(d.width * d.height) { bgra[p * 4] = f[p * 3 + 2]; bgra[p * 4 + 1] = f[p * 3 + 1]; bgra[p * 4 + 2] = f[p * 3] }
                return BGRAImage(width: d.width, height: d.height, bytes: bgra)
            }
            let n = d.frames.count
            var samples = Set([0, n - 1])
            for m in scene.markers { if let k = (0..<n).first(where: { plan.at($0) >= m.at }) { samples.insert(min(k + 1, n - 1)) } }
            let even = max(2, h.value(of: "--samples", in: args).flatMap(Int.init) ?? 30)
            for i in 0..<even { samples.insert(Int((Double(n - 1) * Double(i) / Double(even - 1)).rounded())) }
            var worst = Double.infinity
            var worstFrame = 0
            var checkedNeighbours = 0
            for k in samples.sorted() where k < n {
                let g = gifFrame(k)
                let ref = try await reference(k)
                guard ref.width == g.width, ref.height == g.height else { fail("reference \(ref.width)x\(ref.height) differs from the GIF \(g.width)x\(g.height)"); break }
                let p = FrameCompare.psnr(g, ref)
                if p < worst { worst = p; worstFrame = k }
                if p < Thresholds.gifMinPSNR { fail("frame \(k) PSNR \(String(format: "%.2f", p)) dB < \(Thresholds.gifMinPSNR)") }
                for j in [k - 1, k + 1] where j >= 0 && j < n {
                    let other = try await reference(j)
                    if FrameCompare.psnr(ref, other) < Thresholds.distinctRefPSNR {
                        checkedNeighbours += 1
                        let pj = FrameCompare.psnr(g, other)
                        if pj > p { fail("frame \(k) is closer to the stage frame \(j) (\(String(format: "%.2f", pj)) dB) than to its own (\(String(format: "%.2f", p)) dB)") }
                    }
                }
            }
            c.metrics["sampled"] = Double(samples.count)
            c.metrics["worstPSNR"] = worst.isFinite ? (worst * 100).rounded() / 100 : 99
            c.metrics["worstFrame"] = Double(worstFrame)
            c.metrics["neighbourChecks"] = Double(checkedNeighbours)
        } catch {
            fail(error.friendlyText)
        }
        c.ok = c.failures.isEmpty
        return finish(mode: "gif-check", checks: [c], args: args)
    }
}
