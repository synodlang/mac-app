import CoreMedia
import Foundation

/// The frame schedule of a video or GIF export (pure), over the range [from, to] of the scene.
/// at_k = min(from + k * rate * 1000 / fps, to); N = ceil((to - from) * fps / (1000 * rate)) + 1; PTS k/fps.
/// The default range is the whole scene [0, duration], which is the M8 video schedule.
public struct ExportPlan: Sendable, Equatable {
    public let duration: Double   // ms, of the whole scene
    public let fps: Int
    public let rate: Double
    /// Start of the exported range (ms).
    public let from: Double
    /// End of the exported range (ms).
    public let to: Double
    public let frameCount: Int

    public init(duration: Double, fps: Int = 60, rate: Double = 1, from: Double = 0, to: Double? = nil) {
        precondition(fps > 0 && rate > 0)
        self.duration = max(0, duration)
        self.fps = fps
        self.rate = rate
        let b = min(max(0, to ?? self.duration), self.duration)
        let a = min(max(0, from), b)
        self.from = a
        self.to = b
        self.frameCount = Int(((b - a) * Double(fps) / (1000 * rate)).rounded(.up)) + 1
    }

    /// Presentation time (ms) of frame k.
    public func at(_ k: Int) -> Double {
        min(from + Double(k) * rate * 1000 / Double(fps), to)
    }

    public func pts(_ k: Int) -> CMTime { CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps)) }

    /// Length of the produced video.
    public var videoDuration: CMTime { pts(frameCount) }

    public func batches(of size: Int) -> [Range<Int>] {
        stride(from: 0, to: frameCount, by: size).map { $0..<min($0 + size, frameCount) }
    }
}

public enum ExportSize: String, Sendable, CaseIterable {
    case hd1080, uhd4k

    /// The layout size in CSS pixels (identical for both: 4K is 1080p at pixel ratio 2).
    public var cssWidth: Int { 1920 }
    public var cssHeight: Int { 1080 }
    public var pixelRatio: Double { self == .hd1080 ? 1 : 2 }
    public var pixelWidth: Int { Int(Double(cssWidth) * pixelRatio) }
    public var pixelHeight: Int { Int(Double(cssHeight) * pixelRatio) }
}
