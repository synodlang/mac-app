import CoreVideo
import Foundation
import Testing
@testable import SynodWeb

@Suite struct PixelAndCompareTests {
    func gradient(_ w: Int, _ h: Int) -> BGRAImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            bytes[i] = UInt8((x * 7) & 255); bytes[i + 1] = UInt8((y * 5) & 255); bytes[i + 2] = UInt8((x + y) & 255)
        } }
        return BGRAImage(width: w, height: h, bytes: bytes)
    }

    @Test func pngDecodeIsByteExact() throws {
        let img = gradient(37, 23)
        let png = try PixelBuffers.pngData(from: img)
        #expect(try PixelBuffers.decodePNG(png) == img)
    }

    @Test func pngIntoPixelBufferIsByteExact() throws {
        let img = gradient(64, 48)
        let png = try PixelBuffers.pngData(from: img)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        let buffer = try #require(pb)
        try PixelBuffers.draw(png: png, into: buffer)
        #expect(PixelBuffers.image(from: buffer) == img)
    }

    @Test func badPNG() {
        #expect(throws: PixelError.badPNG) { try PixelBuffers.decodePNG(Data([1, 2, 3])) }
    }

    @Test func identicalIsInfinite() {
        let a = gradient(16, 16)
        #expect(FrameCompare.psnr(a, a) == .infinity)
        #expect(FrameCompare.meanAbsoluteDifference(a, a) == 0)
    }

    @Test func knownNoise() {
        let a = BGRAImage(width: 10, height: 10, b: 100, g: 100, r: 100)
        let b = BGRAImage(width: 10, height: 10, b: 104, g: 104, r: 104)
        let expected = 10 * log10(255.0 * 255.0 / 16)
        #expect(abs(FrameCompare.psnr(a, b) - expected) < 1e-9)
        #expect(FrameCompare.meanAbsoluteDifference(a, b) == 4)
        let c = BGRAImage(width: 10, height: 10, b: 100, g: 100, r: 100, a: 7)
        #expect(FrameCompare.psnr(a, c) == .infinity)
    }

    @Test func partialDifference() {
        let a = BGRAImage(width: 2, height: 1, b: 0, g: 0, r: 0)
        var b = a
        b.bytes[0] = 6
        #expect(FrameCompare.meanAbsoluteDifference(a, b) == 1)
        #expect(abs(FrameCompare.psnr(a, b) - 10 * log10(255.0 * 255.0 / 6)) < 1e-9)
    }

    @Test func diffPNGDecodes() throws {
        let a = gradient(8, 8)
        let png = try FrameCompare.diffPNG(a, a)
        let d = try PixelBuffers.decodePNG(png)
        #expect(d.pixel(3, 3).r == 0)
    }

    @Test func assetsPaths() {
        let base = URL(fileURLWithPath: "/x/Resources")
        let a = WebAssets(baseURL: base)
        #expect(a.playerScriptURL.path == "/x/Resources/player/synod-player.iife.js")
        #expect(a.webDirectory.path == "/x/Resources/web")
        #expect(!a.isComplete)
        #expect(WebAssets.repository().webDirectory.lastPathComponent == "Web")
    }
}
