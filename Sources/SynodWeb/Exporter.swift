import Foundation

public struct ExportOptions: Sendable {
    public var size: ExportSize = .hd1080
    public var codec: VideoCodec = .h264
    public var fps = 60
    /// Viewer speed baked into the video (1 = real time).
    public var rate = 1.0
    /// Stop after this many frames (benchmarks); the file then covers only that prefix.
    public var maxFrames: Int?
    public var batchSize = 8
    public var offscreenWindow = false
    public var bitrate: Int?
    public init() {}
}

public struct ExportProgress: Sendable {
    public let frame: Int
    public let total: Int
    public let framesPerSecond: Double
    public let eta: TimeInterval
}

public struct ExportResult: Sendable {
    public let url: URL
    public let frames: Int
    public let plan: ExportPlan
    public let elapsed: TimeInterval
    public var framesPerSecond: Double { elapsed > 0 ? Double(frames) / elapsed : 0 }
}

/// Renders a scene to an .mp4: batches of PNG frames come from an export web view while the
/// previous batch is decoded and appended on the VideoWriter actor.
@MainActor
public final class Exporter {
    let assets: WebAssets
    public init(assets: WebAssets) { self.assets = assets }

    /// `sceneText` is captured at the call, so later edits do not affect the export.
    /// Cancelling the task deletes the partial file.
    public func export(
        sceneText: String, to url: URL, options: ExportOptions = ExportOptions(),
        progress: (@MainActor (ExportProgress) -> Void)? = nil
    ) async throws -> ExportResult {
        let source = try ExportFrameSource(assets: assets, sceneText: sceneText, size: options.size, offscreenWindow: options.offscreenWindow)
        defer { source.close() }
        let info = try await source.prepare()
        let plan = ExportPlan(duration: info.duration, fps: options.fps, rate: options.rate)
        let total = min(plan.frameCount, options.maxFrames ?? plan.frameCount)
        let settings = VideoSettings(
            width: info.pixelWidth, height: info.pixelHeight, fps: options.fps, codec: options.codec, bitrate: options.bitrate)
        let writer = try VideoWriter(url: url, settings: settings)
        let batches = stride(from: 0, to: total, by: options.batchSize).map { $0..<min($0 + options.batchSize, total) }
        let start = Date()
        do {
            var pending: Task<[Data], Error>? = batches.first.map { b in
                Task { try await source.frames(at: b.map(plan.at)) }
            }
            for (i, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let pngs = try await pending!.value
                pending = i + 1 < batches.count ? {
                    let next = batches[i + 1]
                    return Task { try await source.frames(at: next.map(plan.at)) }
                }() : nil
                for (k, png) in zip(batch, pngs) {
                    try await writer.append(frame: k, png: png)
                }
                if let progress {
                    let done = batch.upperBound
                    let elapsed = Date().timeIntervalSince(start)
                    let fps = elapsed > 0 ? Double(done) / elapsed : 0
                    progress(ExportProgress(frame: done, total: total, framesPerSecond: fps, eta: fps > 0 ? Double(total - done) / fps : 0))
                }
            }
            try await writer.finish(frameCount: total)
        } catch {
            await writer.cancel()
            throw error
        }
        return ExportResult(url: url, frames: total, plan: plan, elapsed: Date().timeIntervalSince(start))
    }
}

// MARK: GIF

public struct GIFExportOptions: Sendable {
    /// Output width in px (480, 640, 800 or 960); the height follows the scene's aspect.
    public var width = GIFLimits.defaultWidth
    public var fps = GIFLimits.defaultFrameRate
    /// Viewer speed baked into the GIF (1 = real time).
    public var rate = 1.0
    /// Presentation-time range in ms; `to` nil means the end of the scene.
    public var from = 0.0
    public var to: Double?
    /// Stop after this many frames (benchmarks).
    public var maxFrames: Int?
    public var batchSize = 8
    public var offscreenWindow = false
    public init() {}
}

public struct GIFExportResult: Sendable {
    public let url: URL
    public let frames: Int
    public let plan: ExportPlan
    public let width: Int
    public let height: Int
    public let bytes: Int
    public let elapsed: TimeInterval
    public var framesPerSecond: Double { elapsed > 0 ? Double(frames) / elapsed : 0 }
}

/// Reads `"canvas":{"w":..,"h":..}` from the first line of a scene.json text.
public enum SceneCanvas {
    public static func parse(_ text: String) -> (w: Double, h: Double)? {
        let head = String(decoding: text.utf8.prefix(while: { $0 != 10 }).prefix(4096), as: UTF8.self)
        guard let r = head.range(of: "\"canvas\"") else { return nil }
        let tail = head[r.upperBound...]
        func number(after key: String) -> Double? {
            guard let k = tail.range(of: "\"\(key)\"") else { return nil }
            let digits = tail[k.upperBound...].drop(while: { $0 == ":" || $0 == " " })
                .prefix(while: { $0.isNumber || $0 == "." })
            return Double(digits)
        }
        guard let w = number(after: "w"), let h = number(after: "h"), w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

extension Exporter {
    /// The plan and size a GIF export would use, or the error that would stop it, for the sheet.
    /// `duration` is the scene's duration in ms; `sceneText` supplies the canvas aspect.
    public static func gifLayout(
        sceneText: String, duration: Double, options: GIFExportOptions
    ) throws -> (plan: ExportPlan, width: Int, height: Int) {
        guard GIFLimits.frameRates.contains(options.fps) else { throw GIFError.badOption("fps \(options.fps)") }
        guard GIFLimits.widths.contains(options.width) else { throw GIFError.badOption("width \(options.width)") }
        guard options.rate > 0 else { throw GIFError.badOption("rate \(options.rate)") }
        let plan = ExportPlan(duration: duration, fps: options.fps, rate: options.rate, from: options.from, to: options.to)
        guard plan.frameCount <= GIFLimits.maxFrames else {
            throw GIFError.tooManyFrames(count: plan.frameCount, limit: GIFLimits.maxFrames)
        }
        let canvas = SceneCanvas.parse(sceneText) ?? (w: 1600, h: 1000)
        return (plan, options.width, GIFLimits.height(width: options.width, canvasWidth: canvas.w, canvasHeight: canvas.h))
    }

    /// Renders a scene (or a range of it) to a GIF89a at `url`, frame by frame: the frames come from the
    /// same export page as a video, are quantized to one global palette from the theme and written as they
    /// arrive. `sceneText` is captured at the call. Cancelling the task deletes the partial file.
    public func exportGIF(
        sceneText: String, to url: URL, options: GIFExportOptions = GIFExportOptions(),
        progress: (@MainActor (ExportProgress) -> Void)? = nil
    ) async throws -> GIFExportResult {
        // Validate before any web view starts, using the duration read from the scene on the page.
        let canvas = SceneCanvas.parse(sceneText) ?? (w: 1600, h: 1000)
        let height = GIFLimits.height(width: options.width, canvasWidth: canvas.w, canvasHeight: canvas.h)
        let source = try ExportFrameSource(
            assets: assets, sceneText: sceneText, width: options.width, height: height, pixelRatio: 1,
            offscreenWindow: options.offscreenWindow)
        defer { source.close() }
        let info = try await source.prepare()
        let (plan, _, _) = try Self.gifLayout(sceneText: sceneText, duration: info.duration, options: options)
        let total = min(plan.frameCount, options.maxFrames ?? plan.frameCount)
        let encoder = try GIFEncoder(
            url: url, width: info.pixelWidth, height: info.pixelHeight, fps: options.fps,
            palette: GIFPalette(sceneText: sceneText))
        let batches = stride(from: 0, to: total, by: options.batchSize).map { $0..<min($0 + options.batchSize, total) }
        let start = Date()
        do {
            var pending: Task<[Data], Error>? = batches.first.map { b in
                Task { try await source.frames(at: b.map(plan.at)) }
            }
            for (i, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let pngs = try await pending!.value
                pending = i + 1 < batches.count ? {
                    let next = batches[i + 1]
                    return Task { try await source.frames(at: next.map(plan.at)) }
                }() : nil
                for png in pngs { try await encoder.append(png: png) }
                if let progress {
                    let done = batch.upperBound
                    let elapsed = Date().timeIntervalSince(start)
                    let fps = elapsed > 0 ? Double(done) / elapsed : 0
                    progress(ExportProgress(frame: done, total: total, framesPerSecond: fps, eta: fps > 0 ? Double(total - done) / fps : 0))
                }
            }
            try await encoder.finish()
        } catch {
            await encoder.cancel()
            throw error
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return GIFExportResult(
            url: url, frames: total, plan: plan, width: info.pixelWidth, height: info.pixelHeight,
            bytes: bytes, elapsed: Date().timeIntervalSince(start))
    }
}
