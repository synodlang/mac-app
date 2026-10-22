import AVFoundation
import Foundation
import SynodCore
import SynodWeb

/// `Synod --acceptance <examples module> --out <dir> [--program raft] [--quick]`:
/// smoke test, then a 1080p60 export of one program decoded back and compared with frames drawn
/// by a separate stage player.
@MainActor
enum Acceptance {
    struct FrameResult: Codable {
        var frame: Int
        var at: Double
        var psnr: Double
        var mad: Double
        var identityChecked: Bool
        var identityOK: Bool
        var why: String
    }

    struct PlanInfo: Codable {
        var durationMs: Double
        var fps: Int
        var rate: Double
        var frameCount: Int
    }

    struct Report: Codable {
        var pass: Bool
        var program: String
        var quick: Bool
        var frames: Int
        var plan: PlanInfo
        var ptsExact: Bool
        var videoDuration: Double
        var nominalFrameRate: Double
        var width: Int
        var height: Int
        var exportSeconds: Double
        var thresholds: [String: Double]
        var samples: Int
        var identityChecks: Int
        var minPSNR: Double
        var medianPSNR: Double
        var maxMAD: Double
        var failures: [String]
        var worst: [FrameResult]
        var results: [FrameResult]
    }

    /// Test hook for the off-by-one demonstration: the reference is drawn this many frames late.
    static let referenceShift = 0

    static func run(_ args: [String]) async -> Int32 {
        let pos = HeadlessCommands.positionals(after: "--acceptance", in: args)
        guard let modulePath = pos.first, let outPath = HeadlessCommands.value(of: "--out", in: args) else {
            HeadlessCommands.fail("usage: --acceptance <module> --out <dir> [--program raft] [--quick]")
            return 2
        }
        let quick = args.contains("--quick")
        let programName = HeadlessCommands.value(of: "--program", in: args) ?? (quick ? "tcp" : "raft")
        let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            HeadlessCommands.fail("cannot create \(out.path): \(error.localizedDescription)")
            return 2
        }
        precondition(AcceptanceThresholds.minPSNR >= AcceptanceThresholds.psnrFloor, "PSNR threshold below the floor")

        HeadlessCommands.note("acceptance: smoke test")
        let smoke = await HeadlessCommands.smoke(["--smoke", modulePath, "--report", out.appendingPathComponent("smoke.json").path])
        if smoke != 0 {
            HeadlessCommands.fail("smoke test failed")
            return 1
        }
        do {
            return try await acceptance(modulePath: modulePath, programName: programName, out: out, quick: quick)
        } catch {
            HeadlessCommands.fail(error.localizedDescription)
            return 1
        }
    }

    private static func acceptance(modulePath: String, programName: String, out: URL, quick: Bool) async throws -> Int32 {
        let ctx = try HeadlessCommands.context(module: modulePath)
        guard let program = ctx.workspace.scan().programs.first(where: { $0.relPath == programName || $0.name == programName }) else {
            throw HeadlessCommands.HeadlessError("no program named \(programName)")
        }
        let outcome = try await ctx.pipeline.run(program: program, options: RunOptions(mode: .ordered, seed: nil))
        guard case .ran(let status, let sceneText, let scene, _) = outcome, case .ok = status.result else {
            throw HeadlessCommands.HeadlessError("the program did not run cleanly: \(HeadlessCommands.describe(outcome))")
        }

        // 1. Export through the normal Exporter.
        let mp4 = out.appendingPathComponent("\(program.name).mp4")
        try? FileManager.default.removeItem(at: mp4)
        let assets = WebAssets.locate()
        var options = ExportOptions()
        options.size = .hd1080
        options.codec = .h264
        options.fps = 60
        options.rate = 1
        var lastPrinted = -1
        let result = try await Exporter(assets: assets).export(sceneText: sceneText, to: mp4, options: options) { p in
            let pct = p.total > 0 ? p.frame * 100 / p.total : 100
            if pct / 10 != lastPrinted {
                lastPrinted = pct / 10
                HeadlessCommands.note(String(format: "export %3d%%  frame %d/%d  %.1f fps  eta %.0fs", pct, p.frame, p.total, p.framesPerSecond, p.eta))
            }
        }
        let plan = result.plan
        let n = plan.frameCount
        var failures: [String] = []

        // 2. Sample selection.
        let samples = sampleFrames(plan: plan, scene: scene, quick: quick)
        HeadlessCommands.note("acceptance: decoding \(n) frames, comparing \(samples.count) samples")

        // 3. Decode.
        let info = try await VideoReader.info(url: mp4)
        let scan = try await VideoReader.scan(url: mp4, keep: Set(samples))
        if scan.frameCount != n { failures.append("frame count \(scan.frameCount), expected \(n)") }
        var ptsExact = scan.frameCount == n
        for (i, t) in scan.pts.enumerated() where CMTimeCompare(t, plan.pts(i)) != 0 {
            ptsExact = false
            failures.append("PTS of frame \(i) is \(CMTimeGetSeconds(t)), expected \(i)/\(plan.fps)")
            break
        }
        let videoSeconds = CMTimeGetSeconds(info.duration)
        let wantSeconds = Double(n) / Double(plan.fps)
        if abs(videoSeconds - wantSeconds) > 1 / Double(plan.fps) {
            failures.append("asset duration \(videoSeconds) s, expected \(wantSeconds) s")
        }
        if abs(Double(info.nominalFrameRate) - Double(plan.fps)) > 0.01 {
            failures.append("nominal frame rate \(info.nominalFrameRate), expected \(plan.fps)")
        }
        if info.width != 1920 || info.height != 1080 { failures.append("size \(info.width)x\(info.height)") }

        // 4. Reference frames from a separate stage player.
        let stage = try StageController(assets: assets, size: CGSize(width: 1920, height: 1080), offscreenWindow: true)
        try await stage.waitUntilReady()
        _ = try await stage.setScene(sceneText, keepTime: false)
        var cache: [Int: BGRAImage] = [:]
        func reference(_ k: Int) async throws -> BGRAImage {
            let kk = min(max(0, k + referenceShift), n - 1)
            if let img = cache[kk] { return img }
            if cache.count > 8 { cache.removeAll() }
            let png = try await stage.renderFramePNG(at: plan.at(kk), width: 1920, height: 1080, pixelRatio: 1)
            let img = try PixelBuffers.decodePNG(png)
            cache[kk] = img
            return img
        }

        var results: [FrameResult] = []
        var identityChecks = 0
        var worstPair: [(Double, Int)] = []
        for k in samples {
            guard let video = scan.frames[k] else {
                failures.append("frame \(k) could not be decoded")
                continue
            }
            let ref = try await reference(k)
            let p = FrameCompare.psnr(video, ref)
            let m = FrameCompare.meanAbsoluteDifference(video, ref)
            var r = FrameResult(frame: k, at: plan.at(k), psnr: min(p, 99), mad: m, identityChecked: false, identityOK: true, why: "")
            if p < AcceptanceThresholds.minPSNR { r.why += "PSNR \(fmt(p)) dB below \(AcceptanceThresholds.minPSNR); " }
            if m > AcceptanceThresholds.maxMAD { r.why += "MAD \(fmt(m)) above \(AcceptanceThresholds.maxMAD); " }
            for j in [k - 1, k + 1] where j >= 0 && j < n {
                let other = try await reference(j)
                if FrameCompare.psnr(ref, other) < AcceptanceThresholds.distinctRefPSNR {
                    r.identityChecked = true
                    identityChecks += 1
                    let po = FrameCompare.psnr(video, other)
                    if !(p > po) {
                        r.identityOK = false
                        r.why += "closer to reference \(j) (\(fmt(po)) dB) than to \(k) (\(fmt(p)) dB); "
                    }
                }
            }
            if !r.why.isEmpty { failures.append("frame \(k): \(r.why)") }
            results.append(r)
            worstPair.append((p, k))
        }
        stage.tearDown()

        // 5. Report and diffs.
        let sorted = results.sorted { $0.psnr < $1.psnr }
        let psnrs = sorted.map(\.psnr)
        let median = psnrs.isEmpty ? 0 : psnrs[psnrs.count / 2]
        for (i, w) in sorted.prefix(3).enumerated() {
            if let video = scan.frames[w.frame] {
                cache.removeAll()
                let ref = try await referenceAgain(w.frame, plan: plan, n: n, assets: assets, sceneText: sceneText)
                let png = try FrameCompare.diffPNG(video, ref)
                try png.write(to: out.appendingPathComponent("diff-\(i + 1)-frame-\(w.frame).png"))
            }
        }
        if samples.isEmpty || results.count != samples.count { failures.append("not every sample was compared") }
        let report = Report(
            pass: failures.isEmpty, program: program.name, quick: quick, frames: scan.frameCount,
            plan: PlanInfo(durationMs: plan.duration, fps: plan.fps, rate: plan.rate, frameCount: n),
            ptsExact: ptsExact, videoDuration: videoSeconds, nominalFrameRate: Double(info.nominalFrameRate),
            width: info.width, height: info.height, exportSeconds: result.elapsed,
            thresholds: ["minPSNR": AcceptanceThresholds.minPSNR, "maxMAD": AcceptanceThresholds.maxMAD,
                         "distinctRefPSNR": AcceptanceThresholds.distinctRefPSNR],
            samples: results.count, identityChecks: identityChecks,
            minPSNR: psnrs.first ?? 0, medianPSNR: median, maxMAD: results.map(\.mad).max() ?? 0,
            failures: Array(failures.prefix(50)), worst: Array(sorted.prefix(3)), results: results.sorted { $0.frame < $1.frame })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: out.appendingPathComponent("report.json"))
        HeadlessCommands.note(String(
            format: "acceptance: %@  frames %d  samples %d  identity checks %d  PSNR min %.2f median %.2f  MAD max %.3f",
            report.pass ? "PASS" : "FAIL", report.frames, report.samples, identityChecks, report.minPSNR, median, report.maxMAD))
        for f in failures.prefix(10) { HeadlessCommands.note("  " + f) }
        return report.pass ? 0 : 1
    }

    /// A fresh stage render of one frame (the main stage was already torn down).
    private static func referenceAgain(_ k: Int, plan: ExportPlan, n: Int, assets: WebAssets, sceneText: String) async throws -> BGRAImage {
        let stage = try StageController(assets: assets, size: CGSize(width: 1920, height: 1080), offscreenWindow: true)
        defer { stage.tearDown() }
        try await stage.waitUntilReady()
        _ = try await stage.setScene(sceneText, keepTime: false)
        let kk = min(max(0, k + referenceShift), n - 1)
        let png = try await stage.renderFramePNG(at: plan.at(kk), width: 1920, height: 1080, pixelRatio: 1)
        return try PixelBuffers.decodePNG(png)
    }

    static func fmt(_ v: Double) -> String { v.isInfinite ? "inf" : String(format: "%.2f", v) }

    /// Sorted unique frame indices: first and last, first frame at/after each marker, evenly
    /// spaced ones and a run of consecutive frames around the busiest second.
    static func sampleFrames(plan: ExportPlan, scene: SceneSummary, quick: Bool) -> [Int] {
        let n = plan.frameCount
        var set: Set<Int> = [0, n - 1]
        for m in scene.markers {
            if let k = (0..<n).first(where: { plan.at($0) >= m.at }) { set.insert(k) }
        }
        let even = quick ? 12 : 60
        for i in 0..<even { set.insert(Int((Double(i) * Double(n - 1) / Double(max(1, even - 1))).rounded())) }
        // Busiest second: most scene trace entries in a one-second bucket.
        var buckets: [Int: Int] = [:]
        for e in scene.trace { buckets[Int(e.at / 1000), default: 0] += 1 }
        if let busiest = buckets.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key {
            let run = quick ? 10 : 30
            let centre = Int((Double(busiest) + 0.5) * Double(plan.fps) / plan.rate)
            let start = min(max(0, centre - run / 2), max(0, n - run))
            for k in start..<min(n, start + run) { set.insert(k) }
        }
        return set.filter { $0 >= 0 && $0 < n }.sorted()
    }
}
