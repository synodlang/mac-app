import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PixelError: Error, Equatable {
    case badPNG
    case bufferUnavailable
    case contextUnavailable
    case encodeFailed
}

/// A tightly packed 8-bit BGRA image (premultiplied alpha, byte order 32 little).
public struct BGRAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// A solid-color image.
    public init(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = a
        }
        self.init(width: width, height: height, bytes: bytes)
    }

    /// (b, g, r) of the pixel at (x, y).
    public func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}

/// PNG <-> BGRA pixel conversions. Everything goes through one sRGB bitmap layout
/// (premultipliedFirst | byteOrder32Little) with no interpolation and the copy blend mode.
public enum PixelBuffers {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func sRGB() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    public static func cgImage(fromPNG data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw PixelError.badPNG }
        return image
    }

    /// Draws `image` into the whole buffer (32BGRA).
    public static func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: sRGB(), bitmapInfo: bitmapInfo) else { throw PixelError.contextUnavailable }
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    public static func draw(png: Data, into buffer: CVPixelBuffer) throws {
        try draw(try cgImage(fromPNG: png), into: buffer)
    }

    public static func decodePNG(_ data: Data) throws -> BGRAImage {
        let image = try cgImage(fromPNG: data)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: sRGB(), bitmapInfo: bitmapInfo) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw PixelError.contextUnavailable }
        return BGRAImage(width: w, height: h, bytes: bytes)
    }

    /// Copies a 32BGRA buffer into a tight image.
    public static func image(from buffer: CVPixelBuffer) -> BGRAImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            bytes.withUnsafeMutableBytes { dst in
                for y in 0..<h {
                    memcpy(dst.baseAddress! + y * w * 4, base + y * stride, w * 4)
                }
            }
        }
        return BGRAImage(width: w, height: h, bytes: bytes)
    }

    public static func pngData(from image: BGRAImage) throws -> Data {
        var bytes = image.bytes
        let cg: CGImage? = bytes.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: sRGB(), bitmapInfo: bitmapInfo)?.makeImage()
        }
        guard let cg else { throw PixelError.contextUnavailable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw PixelError.encodeFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw PixelError.encodeFailed }
        return out as Data
    }

    /// Fills a 32BGRA buffer with one color (tests, synthetic frames).
    public static func fill(_ buffer: CVPixelBuffer, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = a
            }
        }
    }
}
