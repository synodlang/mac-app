import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum VideoCodec: String, Sendable, CaseIterable {
    case h264, hevc
}

public enum VideoWriterError: Error, CustomStringConvertible {
    case cannotStart(String)
    case noPool
    case appendFailed(String)
    case finishFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .cannotStart(let m): return "cannot start video writer: \(m)"
        case .noPool: return "pixel buffer pool unavailable"
        case .appendFailed(let m): return "cannot append frame: \(m)"
        case .finishFailed(let m): return "cannot finish video: \(m)"
        case .cancelled: return "export cancelled"
        }
    }
}

public struct VideoSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: VideoCodec
    public var bitrate: Int

    public init(width: Int, height: Int, fps: Int = 60, codec: VideoCodec = .h264, bitrate: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate ?? Self.defaultBitrate(width: width, height: height, codec: codec)
    }

    /// 1080p: 24 Mbps H.264 / 16 Mbps HEVC; 4K: 80 / 50 Mbps. Smaller frames scale by pixel count.
    public static func defaultBitrate(width: Int, height: Int, codec: VideoCodec) -> Int {
        let pixels = width * height
        if pixels > 1920 * 1080 { return codec == .h264 ? 80_000_000 : 50_000_000 }
        let base = codec == .h264 ? 24_000_000 : 16_000_000
        return max(500_000, base * pixels / (1920 * 1080))
    }
}

/// Writes an .mp4 from frames in order. Frame k gets PTS k/fps.
public actor VideoWriter {
    public let url: URL
    public let settings: VideoSettings
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var finished = false
    private var cancelled = false
    public private(set) var framesWritten = 0

    public init(url: URL, settings: VideoSettings) throws {
        self.url = url
        self.settings = settings
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
        catch { throw VideoWriterError.cannotStart(error.localizedDescription) }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoMaxKeyFrameIntervalKey: 120,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
        ]
        if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let output: [String: Any] = [
            AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
        guard writer.canAdd(input) else { throw VideoWriterError.cannotStart("input not accepted") }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoWriterError.cannotStart(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    /// Appends frame k, filled by `fill` into a pooled 32BGRA buffer.
    public func append(frame k: Int, fill: (CVPixelBuffer) throws -> Void) async throws {
        if cancelled { throw VideoWriterError.cancelled }
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw VideoWriterError.appendFailed(writer.error?.localizedDescription ?? "writer failed")
            }
            if cancelled || Task.isCancelled { throw VideoWriterError.cancelled }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let pool = adaptor.pixelBufferPool else { throw VideoWriterError.noPool }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb
        else { throw VideoWriterError.noPool }
        try fill(buffer)
        let pts = CMTime(value: CMTimeValue(k), timescale: CMTimeScale(settings.fps))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw VideoWriterError.appendFailed(writer.error?.localizedDescription ?? "append refused")
        }
        framesWritten += 1
    }

    /// Appends frame k from a PNG, drawn without color conversion.
    public func append(frame k: Int, png: Data) async throws {
        let image = try PixelBuffers.cgImage(fromPNG: png)
        try await append(frame: k) { try PixelBuffers.draw(image, into: $0) }
    }

    /// Ends the session after `frameCount` frames (duration = frameCount/fps) and closes the file.
    public func finish(frameCount: Int) async throws {
        if cancelled { throw VideoWriterError.cancelled }
        finished = true
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(settings.fps)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoWriterError.finishFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Stops writing and deletes the partial file. Safe to call after finish (then a no-op).
    public func cancel() {
        guard !cancelled, !finished else { return }
        cancelled = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
