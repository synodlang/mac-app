import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SynodWeb

private func tempURL(_ name: String = "t.gif") -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

/// RGB bytes (3 per pixel) of every frame as ImageIO decodes them, plus the container facts.
private struct Decoded {
    var frames: [[UInt8]] = []
    var delays: [Double] = []
    var loopCount: Int?
    var width = 0
    var height = 0
}

private func decode(_ url: URL) throws -> Decoded {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    var d = Decoded()
    if let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
       let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
        d.loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int
    }
    for i in 0..<CGImageSourceGetCount(src) {
        let image = try #require(CGImageSourceCreateImageAtIndex(src, i, nil))
        d.width = image.width; d.height = image.height
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
        for p in 0..<(rgba.count / 4) { rgb.append(contentsOf: [rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2]]) }
        d.frames.append(rgb)
        let fp = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let g = fp?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        d.delays.append((g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? -1)
    }
    return d
}

private func rgb(_ indices: [UInt8], _ palette: GIFPalette) -> [UInt8] {
    indices.flatMap { i -> [UInt8] in let c = palette.colors[Int(i)]; return [c.r, c.g, c.b] }
}

/// A deterministic pseudo-random sequence.
private struct LCG {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
}

private let palette = GIFPalette(theme: brandTheme)
private let W = 64, H = 40

private func frame(_ k: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W where (x / 8 + y / 8) % 2 == 0 { p[y * W + x] = 1 } }
    for y in 10..<20 { for x in (4 + 6 * k)..<(14 + 6 * k) { p[y * W + x] = UInt8(2 + k % 5) } }
    return p
}

@Suite struct GIFEncoderTests {
    @Test func roundTripFramesDelaysSizeLoop() async throws {
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
        let frames = [frame(0), frame(1), frame(1), frame(2), frame(3)]   // frame 2 repeats frame 1
        for f in frames { try await enc.append(indices: f) }
        try await enc.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))
        let d = try decode(url)
        #expect(d.frames.count == frames.count)
        #expect(d.width == W && d.height == H)
        #expect(d.delays.allSatisfy { abs($0 - 0.05) < 1e-9 })
        #expect(d.loopCount == 0)
        for (k, f) in frames.enumerated() { #expect(d.frames[k] == rgb(f, palette), "frame \(k)") }
    }

    @Test func delaysFollowFps() async throws {
        for (fps, delay) in [(10, 10), (20, 5), (25, 4), (50, 2)] {
            #expect(GIFLimits.delay(fps: fps) == delay)
            let url = tempURL()
            let enc = try GIFEncoder(url: url, width: W, height: H, fps: fps, palette: palette)
            try await enc.append(indices: frame(0))
            try await enc.append(indices: frame(1))
            try await enc.finish()
            let d = try decode(url)
            #expect(d.delays.allSatisfy { abs($0 - Double(delay) / 100) < 1e-9 }, "fps \(fps): \(d.delays)")
        }
    }

    @Test func fullTableAndClearCodes() async throws {
        // Noise forces the 12-bit table to fill and clear many times, in the first and in later frames.
        var rng = LCG(s: 7)
        let w = 160, h = 120
        let noisy = (0..<3).map { _ in (0..<(w * h)).map { _ in UInt8(rng.next() % UInt64(palette.colors.count)) } }
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: w, height: h, fps: 25, palette: palette)
        for f in noisy { try await enc.append(indices: f) }
        try await enc.finish()
        let d = try decode(url)
        #expect(d.frames.count == 3)
        for (k, f) in noisy.enumerated() { #expect(d.frames[k] == rgb(f, palette), "frame \(k)") }
    }

    @Test func bgraFramesUseExactPaletteEntries() async throws {
        // Pixels that are exact palette colors come out exactly; near colors snap to the nearest entry.
        let c1 = palette.colors[4], c2 = palette.colors[20]
        func image(_ c: GIFColor, nudge: Int = 0) -> BGRAImage {
            var bytes = [UInt8](repeating: 255, count: 16 * 16 * 4)
            for p in 0..<256 {
                bytes[p * 4] = UInt8(clamping: Int(c.b) + nudge); bytes[p * 4 + 1] = c.g; bytes[p * 4 + 2] = c.r
            }
            return BGRAImage(width: 16, height: 16, bytes: bytes)
        }
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: 16, height: 16, fps: 20, palette: palette)
        try await enc.append(image: image(c1))
        try await enc.append(image: image(c2))
        try await enc.append(image: image(c2, nudge: 1))   // snaps back to c2 (or an equal-distance lower entry)
        try await enc.finish()
        let d = try decode(url)
        #expect(Array(d.frames[0][0..<3]) == [c1.r, c1.g, c1.b])
        #expect(Array(d.frames[1][0..<3]) == [c2.r, c2.g, c2.b])
        let third = Array(d.frames[2][0..<3])
        #expect(palette.colors.contains { [$0.r, $0.g, $0.b] == third })
        #expect(d.frames[2].count == 16 * 16 * 3)
    }

    @Test func sameInputSameBytes() async throws {
        func encode() async throws -> Data {
            let url = tempURL()
            let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
            for k in 0..<4 { try await enc.append(indices: frame(k)) }
            try await enc.finish()
            return try Data(contentsOf: url)
        }
        let a = try await encode(), b = try await encode()
        #expect(a == b)
        #expect(a.prefix(6) == Data("GIF89a".utf8))
        #expect(a.last == 0x3B)
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.contains("NETSCAPE2.0"))
    }

    @Test func laterFramesAreReducedToTheChangedRectangle() async throws {
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
        for k in 0..<4 { try await enc.append(indices: frame(k)) }
        try await enc.finish()
        let small = try Data(contentsOf: url).count
        let url2 = tempURL()
        // The same frames as full frames: each differs everywhere through a flipped background.
        var rng = LCG(s: 1)
        let enc2 = try GIFEncoder(url: url2, width: W, height: H, fps: 20, palette: palette)
        for _ in 0..<4 { try await enc2.append(indices: (0..<(W * H)).map { _ in UInt8(rng.next() % 8) }) }
        try await enc2.finish()
        #expect(small < (try Data(contentsOf: url2).count) / 2)
        #expect(GIFEncoder.changedRect(frame(0), frame(0), width: W, height: H).w == 0)
        let r = GIFEncoder.changedRect(frame(0), frame(1), width: W, height: H)
        #expect(r.x == 4 && r.y == 10 && r.w == 16 && r.h == 10)
    }

    @Test func cancelDeletesPartialFile() async throws {
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
        try await enc.append(indices: frame(0))
        #expect(FileManager.default.fileExists(atPath: url.path + ".partial"))
        await enc.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: GIFError.self) { try await enc.append(indices: frame(1)) }
    }

    @Test func finishWithoutFramesFails() async throws {
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
        await #expect(throws: GIFError.noFrames) { try await enc.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))
    }

    @Test func wrongSizeIsRejected() async throws {
        let url = tempURL()
        let enc = try GIFEncoder(url: url, width: W, height: H, fps: 20, palette: palette)
        let bad = BGRAImage(width: 8, height: 8, b: 0, g: 0, r: 0)
        await #expect(throws: GIFError.self) { try await enc.append(image: bad) }
        await enc.cancel()
    }

    @Test func limitsAndHeights() {
        #expect(GIFLimits.height(width: 640, canvasWidth: 1600, canvasHeight: 1000) == 400)
        #expect(GIFLimits.height(width: 480, canvasWidth: 1600, canvasHeight: 1000) == 300)
        #expect(GIFLimits.height(width: 960, canvasWidth: 1000, canvasHeight: 1000) == 960)
        #expect(GIFLimits.height(width: 800, canvasWidth: 1600, canvasHeight: 900) == 450)
        #expect(GIFLimits.height(width: 640, canvasWidth: 1, canvasHeight: 3) == 1920)
        #expect(GIFLimits.maxFrames == 6000)
    }

    @MainActor @Test func sceneCanvasAndLayout() throws {
        let canvas = try #require(SceneCanvas.parse(brandSceneLine))
        #expect(canvas.w == 1600 && canvas.h == 1000)
        #expect(SceneCanvas.parse("{}") == nil)
        var o = GIFExportOptions()
        o.fps = 20
        let layout = try Exporter.gifLayout(sceneText: brandSceneLine, duration: 18450, options: o)
        #expect(layout.width == 640 && layout.height == 400)
        #expect(layout.plan.frameCount == 370)   // ceil(18450 * 20 / 1000) + 1
        o.fps = 21
        #expect(throws: GIFError.self) { try Exporter.gifLayout(sceneText: brandSceneLine, duration: 18450, options: o) }
        o.fps = 50
        #expect(throws: GIFError.tooManyFrames(count: 7501, limit: 6000)) {
            try Exporter.gifLayout(sceneText: brandSceneLine, duration: 150_000, options: o)
        }
        o.from = 100_000; o.to = 130_000   // 30 s at 50 fps = 1501 frames
        #expect(try Exporter.gifLayout(sceneText: brandSceneLine, duration: 150_000, options: o).plan.frameCount == 1501)
    }
}
