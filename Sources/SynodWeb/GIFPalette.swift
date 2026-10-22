import Foundation

/// An 8-bit sRGB color.
public struct GIFColor: Sendable, Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// "#rrggbb" (either case); nil when malformed.
    public init?(hex: String) {
        let u = Array(hex.utf8)
        guard u.count == 7, u[0] == 35 else { return nil }
        var v = 0
        for c in u[1...] {
            let d: Int
            switch c {
            case 48...57: d = Int(c) - 48
            case 97...102: d = Int(c) - 87
            case 65...70: d = Int(c) - 55
            default: return nil
            }
            v = v * 16 + d
        }
        self.init(r: UInt8(v >> 16 & 255), g: UInt8(v >> 8 & 255), b: UInt8(v & 255))
    }

    /// Lowercase "#rrggbb".
    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// sRGB <-> OKLab on 8-bit colors; the same formulas as the player (`src/math/oklab.ts`).
enum OKLab {
    static func toLinear(_ c8: UInt8) -> Double {
        let c = Double(c8) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func fromLinear(_ x: Double) -> UInt8 {
        let c = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        let v = (c * 255).rounded()   // like Math.round for the positive range
        return v < 0 ? 0 : v > 255 ? 255 : UInt8(v)
    }

    static func lab(_ c: GIFColor) -> SIMD3<Double> {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    static func color(_ v: SIMD3<Double>) -> GIFColor {
        let l_ = v.x + 0.3963377774 * v.y + 0.2158037573 * v.z
        let m_ = v.x - 0.1055613458 * v.y - 0.0638541728 * v.z
        let s_ = v.x - 0.0894841775 * v.y - 1.291485548 * v.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return GIFColor(
            r: fromLinear(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            g: fromLinear(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            b: fromLinear(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s))
    }

    /// Linear mix in OKLab at fraction u, back to 8-bit sRGB.
    static func mix(_ a: GIFColor, _ b: GIFColor, _ u: Double) -> GIFColor {
        let x = lab(a), y = lab(b)
        return color(x + (y - x) * u)
    }
}

/// The global palette of a GIF: at most 256 entries derived from the scene theme (decision 88).
///
/// 1. Entry 0 is Paper, then each other theme color in file order (n entries).
/// 2. For each non-Paper color c: `s = min(15, floor((256 - n) / (n - 1)))` OKLab mixes Paper -> c at u = j / (s + 1).
/// 3. Then, for each color not Paper or Ink: `s2 = min(7, floor(remaining / (n - 2)))` mixes Ink -> c.
/// Duplicates are kept. The result is a pure function of the theme.
public struct GIFPalette: Sendable, Equatable {
    public static let capacity = 256
    public static let defaultPaper = GIFColor(r: 0x15, g: 0x1A, b: 0x2E)

    public let colors: [GIFColor]

    public init(colors: [GIFColor]) {
        precondition(!colors.isEmpty && colors.count <= Self.capacity)
        self.colors = colors
    }

    /// Builds the palette from the theme entries in file order.
    public init(theme: [(name: String, color: GIFColor)]) {
        let paper = theme.first { $0.name == "Paper" }?.color ?? Self.defaultPaper
        let ink = theme.first { $0.name == "Ink" }?.color
        let others = theme.filter { $0.name != "Paper" }
        var base = [paper] + others.map(\.color)
        if base.count > Self.capacity { base = Array(base[0..<Self.capacity]) }
        let n = base.count
        var out = base
        if n >= 2 {
            let s = min(15, (Self.capacity - n) / (n - 1))
            if s > 0 {
                for c in base.dropFirst() {
                    for j in 1...s { out.append(OKLab.mix(paper, c, Double(j) / Double(s + 1))) }
                }
            }
            if let ink, n > 2 {
                let remaining = Self.capacity - out.count
                let s2 = min(7, remaining / (n - 2))
                if s2 > 0 {
                    for entry in others where entry.name != "Ink" {
                        for j in 1...s2 { out.append(OKLab.mix(ink, entry.color, Double(j) / Double(s2 + 1))) }
                    }
                }
            }
        }
        colors = out
    }

    /// The palette of a scene.json text (its `theme`).
    public init(sceneText: String) {
        self.init(theme: Self.theme(inSceneText: sceneText))
    }

    /// The theme entries in file order, read from the scene's first line (`"theme":{...}`).
    /// Entries whose value is not "#rrggbb" are skipped.
    public static func theme(inSceneText text: String) -> [(name: String, color: GIFColor)] {
        let head = text.utf8.prefix(while: { $0 != 10 })   // the format line holds the theme
        let bytes = Array(head)
        let key = Array("\"theme\"".utf8)
        guard let start = find(key, in: bytes) else { return [] }
        var i = start + key.count
        func skipSpace() { while i < bytes.count, bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 13 { i += 1 } }
        func string() -> String? {
            guard i < bytes.count, bytes[i] == 34 else { return nil }
            i += 1
            var raw: [UInt8] = []
            while i < bytes.count, bytes[i] != 34 {
                if bytes[i] == 92, i + 1 < bytes.count { i += 1 }
                raw.append(bytes[i]); i += 1
            }
            guard i < bytes.count else { return nil }
            i += 1
            return String(decoding: raw, as: UTF8.self)
        }
        skipSpace()
        guard i < bytes.count, bytes[i] == 58 else { return [] }
        i += 1; skipSpace()
        guard i < bytes.count, bytes[i] == 123 else { return [] }
        i += 1
        var result: [(name: String, color: GIFColor)] = []
        while true {
            skipSpace()
            if i < bytes.count, bytes[i] == 125 { break }
            guard let name = string() else { break }
            skipSpace()
            guard i < bytes.count, bytes[i] == 58 else { break }
            i += 1; skipSpace()
            guard let value = string() else { break }
            if let c = GIFColor(hex: value) { result.append((name, c)) }
            skipSpace()
            if i < bytes.count, bytes[i] == 44 { i += 1 }
        }
        return result
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for s in 0...(hay.count - needle.count) where hay[s] == needle[0] {
            if hay[s..<(s + needle.count)].elementsEqual(needle) { return s }
        }
        return nil
    }
}

/// Maps colors to the nearest palette entry in OKLab (squared distance, ties to the lower
/// index), no dithering. Results are cached per distinct color.
public struct GIFQuantizer {
    public let palette: GIFPalette
    private let labs: [SIMD3<Double>]
    private var cache: [UInt32: UInt8] = [:]

    public init(palette: GIFPalette) {
        self.palette = palette
        labs = palette.colors.map(OKLab.lab)
    }

    public mutating func index(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let hit = cache[key] { return hit }
        let target = OKLab.lab(GIFColor(r: r, g: g, b: b))
        var best = 0
        var bestD = Double.infinity
        for (i, l) in labs.enumerated() {
            let d = l - target
            let dist = d.x * d.x + d.y * d.y + d.z * d.z
            if dist < bestD { bestD = dist; best = i }
        }
        let result = UInt8(best)
        cache[key] = result
        return result
    }

    /// Palette indices (row-major) of a BGRA image.
    public mutating func indices(of image: BGRAImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        image.bytes.withUnsafeBufferPointer { px in
            for p in 0..<out.count {
                out[p] = index(r: px[p * 4 + 2], g: px[p * 4 + 1], b: px[p * 4])
            }
        }
        return out
    }
}
