import Foundation

/// Where a token's declaration is: a module-relative file (or `<module>@<v>/path` for a vendored
/// one), 1-based line, 1-based column in code points.
public struct TokenDefinition: Sendable, Hashable, Decodable {
    public let file: String
    public let line: Int
    public let col: Int
    public init(file: String, line: Int, col: Int) {
        self.file = file
        self.line = line
        self.col = col
    }
}

/// One token of `synod check --json --tokens` (`04-formats.md`).
public struct SynodToken: Sendable, Hashable, Decodable {
    /// The role of a word. Roles this build does not know decode as `.unknown`, so a newer
    /// compiler never breaks highlighting.
    public enum Role: String, Sendable, CaseIterable {
        case language, phrase, name, field, type, value, comment, unknown
    }

    /// 1-based line.
    public let line: Int
    /// 1-based column in code points.
    public let col: Int
    /// Length in code points.
    public let len: Int
    public let role: Role
    /// Where the word is declared; nil for std and language words and for lexical-only tokens.
    public let def: TokenDefinition?

    public init(line: Int, col: Int, len: Int, role: Role, def: TokenDefinition? = nil) {
        self.line = line
        self.col = col
        self.len = len
        self.role = role
        self.def = def
    }

    enum CodingKeys: String, CodingKey { case line, col, len, role, def }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decode(Int.self, forKey: .line)
        col = try c.decode(Int.self, forKey: .col)
        len = try c.decode(Int.self, forKey: .len)
        let raw = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        role = Role(rawValue: raw) ?? .unknown
        def = try c.decodeIfPresent(TokenDefinition.self, forKey: .def)
    }
}

/// The tokens of one file, sorted by position.
public struct FileTokens: Sendable, Equatable, Decodable {
    /// Module-relative slash path.
    public let file: String
    public let tokens: [SynodToken]

    public init(file: String, tokens: [SynodToken]) {
        self.file = file
        self.tokens = tokens
    }

    enum CodingKeys: String, CodingKey { case file, tokens }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        tokens = try c.decodeIfPresent([SynodToken].self, forKey: .tokens) ?? []
    }

    /// True when the file looks like a lexical fallback (decision 79): every role is one of
    /// `language`, `value`, `comment`, `name` and no token has a `def`. A fully resolved file that
    /// is tiny can look the same; the app only uses this to tone down go-to-definition hints.
    public var looksLexicalOnly: Bool {
        tokens.allSatisfy { t in
            t.def == nil && (t.role == .language || t.role == .value || t.role == .comment || t.role == .name)
        }
    }

    /// The token that covers the 1-based `line` and `col`, if any.
    public func token(atLine line: Int, col: Int) -> SynodToken? {
        // Sorted by position: binary search for the last token starting at or before the point.
        var lo = 0
        var hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let t = tokens[mid]
            if (t.line, t.col) <= (line, col) { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let t = tokens[lo - 1]
        return t.line == line && col < t.col + t.len ? t : nil
    }
}

extension CheckReport {
    /// The tokens of a file (module-relative path), when `--tokens` was used.
    public func tokens(for file: String) -> FileTokens? {
        files.first { $0.file == file }
    }

    /// Resolves a token's `def` to a module-relative path for opening: a vendored file
    /// `<module>@<v>/path` lives in `vendor/<module>@<v>/path`.
    public static func workspacePath(ofDefinitionFile file: String) -> String {
        guard let at = file.firstIndex(of: "@"), at != file.startIndex else { return file }
        // A vendored path has an `@version` inside its first path components and is not already
        // under vendor/.
        if file.hasPrefix("vendor/") { return file }
        let head = file[..<at]
        return head.contains("/") || head.contains(".") ? "vendor/" + file : file
    }
}
