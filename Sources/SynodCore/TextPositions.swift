import Foundation

/// Converts between the compiler's positions (1-based line, 1-based column counted in code
/// points) and offsets into the same text in UTF-16 (what `NSString`/TextKit use) or UTF-8.
///
/// Lines end at `\n`; a `\r` before it counts as an ordinary character of the line. The text after
/// the last `\n` is the last line, so a file ending in a newline has an empty final line, where a
/// compiler edit that appends whole lines inserts.
public struct TextPositions: Sendable {
    private let scalars: [Unicode.Scalar]
    /// Index into `scalars` of the first scalar of each line.
    private let lineStarts: [Int]
    /// `utf16Prefix[i]`/`utf8Prefix[i]`: the offset of scalar `i`; one extra entry for the end.
    private let utf16Prefix: [Int]
    private let utf8Prefix: [Int]

    public init(_ text: String) {
        let sc = Array(text.unicodeScalars)
        var starts = [0]
        var u16 = [Int](repeating: 0, count: sc.count + 1)
        var u8 = [Int](repeating: 0, count: sc.count + 1)
        for (i, s) in sc.enumerated() {
            u16[i + 1] = u16[i] + (s.value > 0xFFFF ? 2 : 1)
            u8[i + 1] = u8[i] + UTF8.width(s)
            if s == "\n" { starts.append(i + 1) }
        }
        scalars = sc
        lineStarts = starts
        utf16Prefix = u16
        utf8Prefix = u8
    }

    /// The number of lines (at least 1).
    public var lineCount: Int { lineStarts.count }
    /// The length of the text in UTF-16 code units.
    public var utf16Length: Int { utf16Prefix[scalars.count] }
    /// The length of the text in UTF-8 bytes.
    public var utf8Length: Int { utf8Prefix[scalars.count] }

    /// The scalar index of a position, or nil when the line or column is outside the text. The
    /// column just after the last character of a line is valid.
    public func scalarIndex(line: Int, col: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, col >= 1 else { return nil }
        let start = lineStarts[line - 1]
        let end = lineEnd(line)
        let idx = start + col - 1
        return idx <= end ? idx : nil
    }

    /// Scalar index just before the line's `\n` (or the end of text).
    private func lineEnd(_ line: Int) -> Int {
        line < lineStarts.count ? lineStarts[line] - 1 : scalars.count
    }

    public func utf16Offset(line: Int, col: Int) -> Int? {
        scalarIndex(line: line, col: col).map { utf16Prefix[$0] }
    }

    public func utf8Offset(line: Int, col: Int) -> Int? {
        scalarIndex(line: line, col: col).map { utf8Prefix[$0] }
    }

    /// The UTF-16 range of `len` code points starting at the position; nil when it does not fit.
    public func utf16Range(line: Int, col: Int, len: Int) -> NSRange? {
        guard len >= 0, let s = scalarIndex(line: line, col: col), s + len <= scalars.count else { return nil }
        return NSRange(location: utf16Prefix[s], length: utf16Prefix[s + len] - utf16Prefix[s])
    }

    /// The UTF-16 range from one position to another (`end` exclusive, as the compiler writes it).
    public func utf16Range(from: SourcePosition, to: SourcePosition) -> NSRange? {
        guard let a = utf16Offset(line: from.line, col: from.col), let b = utf16Offset(line: to.line, col: to.col), b >= a else {
            return nil
        }
        return NSRange(location: a, length: b - a)
    }

    /// The UTF-16 range of a line without its newline.
    public func utf16LineRange(_ line: Int) -> NSRange? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let a = utf16Prefix[lineStarts[line - 1]]
        return NSRange(location: a, length: utf16Prefix[lineEnd(line)] - a)
    }

    /// The position of a UTF-16 offset; nil when it is outside the text or inside a surrogate pair.
    public func position(utf16Offset off: Int) -> SourcePosition? {
        guard off >= 0, off <= utf16Length, let i = Self.scalarIndex(of: off, in: utf16Prefix) else { return nil }
        return position(scalarIndex: i)
    }

    /// The position of a UTF-8 byte offset; nil when it is outside the text or inside a character.
    public func position(utf8Offset off: Int) -> SourcePosition? {
        guard off >= 0, off <= utf8Length, let i = Self.scalarIndex(of: off, in: utf8Prefix) else { return nil }
        return position(scalarIndex: i)
    }

    /// The UTF-16 offset of a UTF-8 offset (nil off a character boundary).
    public func utf16Offset(utf8Offset off: Int) -> Int? {
        guard off >= 0, off <= utf8Length, let i = Self.scalarIndex(of: off, in: utf8Prefix) else { return nil }
        return utf16Prefix[i]
    }

    private func position(scalarIndex i: Int) -> SourcePosition {
        // Last line starting at or before i.
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if lineStarts[mid] <= i { lo = mid + 1 } else { hi = mid }
        }
        let line = lo
        return SourcePosition(line: line, col: i - lineStarts[line - 1] + 1)
    }

    /// Binary search of an exact offset in a prefix array.
    private static func scalarIndex(of off: Int, in prefix: [Int]) -> Int? {
        var lo = 0
        var hi = prefix.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if prefix[mid] < off { lo = mid + 1 } else { hi = mid }
        }
        return lo < prefix.count && prefix[lo] == off ? lo : nil
    }
}
