import CoreMedia
import Foundation

/// The frame schedule of a video export (pure).
/// at_k = min(k * rate * 1000 / fps, duration); N = ceil(duration * fps / (1000 * rate)) + 1; PTS k/fps.
public struct ExportPlan: Sendable, Equatable {
    public let duration: Double   // ms
    public let fps: Int
    public let rate: Double
    public let frameCount: Int

    public init(duration: Double, fps: Int = 60, rate: Double = 1) {
        precondition(fps > 0 && rate > 0)
        self.duration = max(0, duration)
        self.fps = fps
        self.rate = rate
        self.frameCount = Int((self.duration * Double(fps) / (1000 * rate)).rounded(.up)) + 1
    }

    /// Presentation time (ms) of frame k.
    public func at(_ k: Int) -> Double {
        min(Double(k) * rate * 1000 / Double(fps), duration)
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
