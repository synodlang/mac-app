import Foundation

/// Simulated time in microseconds, displayed as a canonical Synod duration.
public struct SimTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let microseconds: Int64
    public init(microseconds: Int64) { self.microseconds = microseconds }
    public static func < (a: SimTime, b: SimTime) -> Bool { a.microseconds < b.microseconds }
    /// The canonical literal: `2s`, `250ms`, `0.5ms`.
    public var description: String { FormatTime.string(microseconds: microseconds) }
}

/// Canonical duration text, a port of the compiler's `value.FormatTime` and `lex.CanonicalDuration`.
public enum FormatTime {
    /// `2s`, `1500ms`, `0.5ms`, `0.001ms`, `0s`, `-1500ms` for `microseconds`.
    public static func string(microseconds us: Int64) -> String {
        let neg = us < 0
        let u: UInt64 = neg ? UInt64(bitPattern: 0 &- us) : UInt64(us)
        var ms = String(u / 1000)
        let frac = u % 1000
        if frac != 0 {
            var f = String(frac + 1000).dropFirst()
            while f.last == "0" { f.removeLast() }
            ms += "." + f
        }
        if neg && ms != "0" { ms = "-" + ms }
        return canonical(milliseconds: ms)
    }

    /// Whole seconds are written in seconds, everything else in milliseconds.
    private static func canonical(milliseconds ms: String) -> String {
        if ms == "0" { return "0s" }
        if !ms.contains("."), ms.hasSuffix("000") { return String(ms.dropLast(3)) + "s" }
        return ms + "ms"
    }

    /// Parses `2s`, `1500ms`, `0.5ms`, `147.98s` (optionally negative) to microseconds.
    public static func parse(_ text: String) -> Int64? {
        var s = Substring(text)
        var neg = false
        if s.hasPrefix("-") { neg = true; s = s.dropFirst() }
        var scale: Int64 = 1_000_000  // microseconds per unit
        if s.hasSuffix("ms") { s = s.dropLast(2); scale = 1000 } else if s.hasSuffix("s") { s = s.dropLast() } else { return nil }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]), parts[0].allSatisfy(\.isASCII) else { return nil }
        var micros = whole * scale
        if parts.count == 2 {
            let digits = parts[1]
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            // fraction * scale, exact to 1 microsecond
            var num: Int64 = 0
            var den: Int64 = 1
            for d in digits.prefix(9) {
                num = num * 10 + Int64(d.wholeNumberValue ?? 0)
                den *= 10
            }
            micros += num * scale / den
        }
        return neg ? -micros : micros
    }
}

/// Number text as the compiler writes it (ECMAScript `Number::toString`).
public enum FormatNumber {
    public static func string(_ f: Double) -> String {
        if f == 0 { return "0" }
        if !f.isFinite { return f.isNaN ? "NaN" : (f < 0 ? "-Infinity" : "Infinity") }
        // Shortest round-trip digits from Swift's description: "-1.2345e-07", "123.5", "1e+21".
        var d = "\(abs(f))"
        var exp10 = 0
        if let e = d.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp10 = Int(d[d.index(after: e)...]) ?? 0
            d = String(d[..<e])
        }
        var intPart = d
        var fracPart = ""
        if let dot = d.firstIndex(of: ".") {
            intPart = String(d[..<dot])
            fracPart = String(d[d.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var pointPos = intPart.count + exp10  // value = 0.digits... no: digits with point after pointPos digits
        // Strip leading zeros.
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            pointPos -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let sign = f < 0 ? "-" : ""
        let abs = Swift.abs(f)
        if abs >= 1e-6 && abs < 1e21 {
            if pointPos <= 0 {
                return sign + "0." + String(repeating: "0", count: -pointPos) + digits
            } else if pointPos >= digits.count {
                return sign + digits + String(repeating: "0", count: pointPos - digits.count)
            } else {
                let idx = digits.index(digits.startIndex, offsetBy: pointPos)
                return sign + digits[..<idx] + "." + digits[idx...]
            }
        }
        let e = pointPos - 1
        var mant = String(digits.first!)
        if digits.count > 1 { mant += "." + digits.dropFirst() }
        return sign + mant + "e" + (e < 0 ? "-" : "+") + String(Swift.abs(e))
    }
}
