import Foundation

/// A replacement of a UTF-16 range of a buffer.
public struct TextEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// The UTF-16 length of the replacement.
    public var replacementLength: Int { (replacement as NSString).length }

    /// The edits of a compiler `help`, as UTF-16 edits of the text `positions` describes, in
    /// descending position order so they can be applied one after the other without shifting.
    /// Nil when an edit does not fit the text. (Edits of one help never overlap.)
    public static func edits(from help: CheckReport.Help, in positions: TextPositions) -> [TextEdit]? {
        var result: [TextEdit] = []
        for e in help.edits {
            guard let r = positions.utf16Range(from: SourcePosition(line: e.line, col: e.col), to: e.end) else { return nil }
            result.append(TextEdit(range: r, replacement: e.new))
        }
        // Equal locations (two inserts at one point) keep their original order, applied last first.
        let indexed = result.enumerated().sorted { a, b in
            a.element.range.location != b.element.range.location
                ? a.element.range.location > b.element.range.location : a.offset > b.offset
        }
        return indexed.map(\.element)
    }

    /// Applies `edits` (descending, non-overlapping) to `text`.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        let ns = NSMutableString(string: text)
        for e in edits { ns.replaceCharacters(in: e.range, with: e.replacement) }
        return ns as String
    }
}

/// A token placed in a buffer: its UTF-16 range, role and definition.
public struct PositionedToken: Sendable, Equatable {
    public var range: NSRange
    public let role: SynodToken.Role
    public let def: TokenDefinition?
    public init(range: NSRange, role: SynodToken.Role, def: TokenDefinition? = nil) {
        self.range = range
        self.role = role
        self.def = def
    }

    /// Places a file's tokens in its text. Tokens that do not fit the text are left out.
    public static func place(_ tokens: [SynodToken], in positions: TextPositions) -> [PositionedToken] {
        tokens.compactMap { t in
            positions.utf16Range(line: t.line, col: t.col, len: t.len).map { PositionedToken(range: $0, role: t.role, def: t.def) }
        }
    }
}

/// Moves token ranges with the edits made since the check (decision 78): tokens after an edit
/// shift, tokens overlapping it are dropped, tokens before it stay. The app has no lexer, so a
/// dropped word simply loses its color until the next check.
public enum TokenShifter {
    /// The tokens after the buffer's `range` was replaced by `replacementLength` UTF-16 units.
    /// A token that only touches the edit (ends where it starts, or starts where it ends) is kept.
    public static func shift(_ tokens: [PositionedToken], replacing range: NSRange, withLength replacementLength: Int) -> [PositionedToken] {
        let a = range.location
        let b = range.location + range.length
        let delta = replacementLength - range.length
        var result: [PositionedToken] = []
        result.reserveCapacity(tokens.count)
        for var t in tokens {
            let s = t.range.location
            let e = s + t.range.length
            if e <= a {
                result.append(t)
            } else if s >= b {
                t.range.location += delta
                result.append(t)
            }
            // else: overlaps the edit, dropped
        }
        return result
    }

    /// Applies several edits in the order given; each is in the coordinates left by the one before.
    public static func shift(_ tokens: [PositionedToken], edits: [TextEdit]) -> [PositionedToken] {
        edits.reduce(tokens) { shift($0, replacing: $1.range, withLength: $1.replacementLength) }
    }
}
