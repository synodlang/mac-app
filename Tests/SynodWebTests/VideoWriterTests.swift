import AVFoundation
import Foundation
import Testing
@testable import SynodWeb

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("synod-\(UUID().uuidString)-\(name)")
}

@Suite struct VideoWriterTests {
    func roundTrip(_ codec: VideoCodec) async throws {
        let url = tempURL("sync.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let n = 120
        let settings = VideoSettings(width: 320, height: 180, fps: 60, codec: codec, bitrate: 2_000_000)
        let writer = try VideoWriter(url: url, settings: settings)
        for k in 0..<n {
            try await writer.append(frame: k) { PixelBuffers.fill($0, b: UInt8(2 * k), g: UInt8(2 * k), r: UInt8(2 * k)) }
        }
        try await writer.finish(frameCount: n)

        let info = try await VideoReader.info(url: url)
        #expect(abs(info.duration.seconds - 2.0) < 1e-6)
        #expect(abs(info.nominalFrameRate - 60) < 0.01)
        #expect(info.width == 320 && info.height == 180)

        let scan = try await VideoReader.scan(url: url, keep: Set(0..<n))
        #expect(scan.frameCount == n)
        for k in 0..<n {
            #expect(scan.pts[k] == CMTime(value: CMTimeValue(k), timescale: 60), "pts \(k)")
            guard let f = scan.frames[k] else { Issue.record("missing frame \(k)"); continue }
            let p = f.pixel(160, 90)
            let decoded = (Int(p.b) + Int(p.g) + Int(p.r)) / 3 / 2
            #expect(abs(decoded - k) <= 2, "frame \(k) decoded as \(decoded)")
        }
    }

    @Test func h264() async throws { try await roundTrip(.h264) }
    @Test func hevc() async throws { try await roundTrip(.hevc) }

    @Test func cancelDeletesFile() async throws {
        let url = tempURL("cancel.mp4")
        let writer = try VideoWriter(url: url, settings: VideoSettings(width: 64, height: 64, fps: 30, bitrate: 500_000))
        for k in 0..<5 {
            try await writer.append(frame: k) { PixelBuffers.fill($0, b: 10, g: 20, r: 30) }
        }
        await writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: VideoWriterError.self) {
            try await writer.append(frame: 5) { _ in }
        }
    }

    @Test func pngFramesAppend() async throws {
        let url = tempURL("png.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try PixelBuffers.pngData(from: BGRAImage(width: 128, height: 72, b: 200, g: 100, r: 50))
        let writer = try VideoWriter(url: url, settings: VideoSettings(width: 128, height: 72, fps: 30, bitrate: 500_000))
        for k in 0..<10 { try await writer.append(frame: k, png: png) }
        try await writer.finish(frameCount: 10)
        let scan = try await VideoReader.scan(url: url, keep: [9])
        #expect(scan.frameCount == 10)
        let p = try #require(scan.frames[9]).pixel(10, 10)
        #expect(abs(Int(p.r) - 50) <= 4 && abs(Int(p.g) - 100) <= 4 && abs(Int(p.b) - 200) <= 4)
    }
}
