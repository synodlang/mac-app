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
    private let assets: WebAssets
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
