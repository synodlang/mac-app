import Foundation

/// Image similarity on the 8-bit RGB channels (alpha ignored).
public enum FrameCompare {
    /// Sum of squared channel differences and of absolute differences over RGB.
    private static func sums(_ a: BGRAImage, _ b: BGRAImage) -> (sq: Double, abs: Double, n: Double) {
        precondition(a.width == b.width && a.height == b.height, "frame sizes differ")
        var sq: UInt64 = 0, ab: UInt64 = 0
        a.bytes.withUnsafeBufferPointer { pa in
            b.bytes.withUnsafeBufferPointer { pb in
                var i = 0
                let n = pa.count
                while i < n {
                    for c in 0..<3 {
                        let d = Int(pa[i + c]) - Int(pb[i + c])
                        sq += UInt64(d * d)
                        ab += UInt64(d < 0 ? -d : d)
                    }
                    i += 4
                }
            }
        }
        return (Double(sq), Double(ab), Double(a.width * a.height * 3))
    }

    /// Peak signal-to-noise ratio in dB; infinity for identical images.
    public static func psnr(_ a: BGRAImage, _ b: BGRAImage) -> Double {
        let s = sums(a, b)
        if s.sq == 0 { return .infinity }
        return 10 * log10(255.0 * 255.0 / (s.sq / s.n))
    }

    /// Mean absolute channel difference on the 0...255 scale.
    public static func meanAbsoluteDifference(_ a: BGRAImage, _ b: BGRAImage) -> Double {
        let s = sums(a, b)
        return s.abs / s.n
    }

    /// A PNG of |a - b| per channel times `gain`, opaque.
    public static func diffPNG(_ a: BGRAImage, _ b: BGRAImage, gain: Int = 8) throws -> Data {
        precondition(a.width == b.width && a.height == b.height)
        var out = a
        for i in stride(from: 0, to: out.bytes.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c])) * gain
                out.bytes[i + c] = UInt8(min(255, d))
            }
            out.bytes[i + 3] = 255
        }
        return try PixelBuffers.pngData(from: out)
    }
}
