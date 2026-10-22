import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct VideoInfo: Sendable, Equatable {
    public let duration: CMTime
    public let nominalFrameRate: Float
    public let width: Int
    public let height: Int
}

public struct VideoScan: Sendable {
    /// Presentation time of every frame, in the order the reader returned them.
    public let pts: [CMTime]
    /// The requested frames, by index.
    public let frames: [Int: BGRAImage]
    public var frameCount: Int { pts.count }
}

public enum VideoReaderError: Error, CustomStringConvertible {
    case noVideoTrack
    case readerFailed(String)
    public var description: String {
        switch self {
        case .noVideoTrack: return "no video track"
        case .readerFailed(let m): return "cannot read video: \(m)"
        }
    }
}

/// Reads a video back as BGRA through AVAssetReader (used by tests and the acceptance run).
public enum VideoReader {
    public static func info(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoReaderError.noVideoTrack
        }
        let rate = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        return VideoInfo(duration: duration, nominalFrameRate: rate, width: Int(size.width), height: Int(size.height))
    }

    /// Decodes the whole video once, keeping only the frames in `keep`.
    public static func scan(url: URL, keep: Set<Int> = []) async throws -> VideoScan {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoReaderError.noVideoTrack
            }
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw VideoReaderError.readerFailed("output not accepted") }
            reader.add(out)
            guard reader.startReading() else {
                throw VideoReaderError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
            }
            var pts: [CMTime] = []
            var frames: [Int: BGRAImage] = [:]
            while let sample = out.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let index = pts.count
                pts.append(CMSampleBufferGetPresentationTimeStamp(sample))
                if keep.contains(index), let pb = CMSampleBufferGetImageBuffer(sample) {
                    frames[index] = PixelBuffers.image(from: pb)
                }
            }
            if reader.status == .failed {
                throw VideoReaderError.readerFailed(reader.error?.localizedDescription ?? "failed")
            }
            return VideoScan(pts: pts, frames: frames)
        }.value
    }
}
