import Foundation

/// A line and column, 1-based, columns in code points.
public struct SourcePosition: Sendable, Hashable, Decodable {
    public let line: Int
    public let col: Int
    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
}

/// The result of `synod check --json` (format `synod-check/1`). Unknown keys are ignored, a major
/// version other than 1 is rejected.
public struct CheckReport: Sendable, Equatable, Decodable {
    /// A secondary span, possibly in another file.
    public struct Label: Sendable, Equatable, Decodable {
        public let file: String
        public let line: Int
        public let col: Int
        public let end: SourcePosition
        public let text: String
    }

    /// A replacement of a span in the diagnostic's own file; an empty span inserts.
    public struct Edit: Sendable, Equatable, Decodable {
        public let line: Int
        public let col: Int
        public let end: SourcePosition
        public let new: String
    }

    /// A suggested fix. The app shows the text and does not apply edits in M8.
    public struct Help: Sendable, Equatable, Decodable {
        public let text: String
        public let edits: [Edit]

        enum CodingKeys: String, CodingKey { case text, edits }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            edits = try c.decodeIfPresent([Edit].self, forKey: .edits) ?? []
        }
    }

    public struct Diagnostic: Sendable, Equatable, Decodable, Identifiable {
        /// Module-relative slash path.
        public let file: String
        public let line: Int
        public let col: Int
        /// The position just after the primary span (exclusive).
        public let end: SourcePosition
        /// `error`, `warning`, ...
        public let severity: String
        public let code: String
        public let message: String
        public let hint: String?
        /// The text under the primary span.
        public let label: String?
        public let labels: [Label]
        public let help: [Help]
        public let notes: [String]

        public var isError: Bool { severity == "error" }
        public var id: String { "\(file):\(line):\(col):\(code):\(message)" }

        enum CodingKeys: String, CodingKey {
            case file, line, col, end, severity, code, message, hint, label, labels, help, notes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decode(String.self, forKey: .file)
            line = try c.decode(Int.self, forKey: .line)
            col = try c.decode(Int.self, forKey: .col)
            end = try c.decodeIfPresent(SourcePosition.self, forKey: .end) ?? SourcePosition(line: line, col: col)
            severity = try c.decode(String.self, forKey: .severity)
            code = try c.decode(String.self, forKey: .code)
            message = try c.decode(String.self, forKey: .message)
            hint = try c.decodeIfPresent(String.self, forKey: .hint)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            labels = try c.decodeIfPresent([Label].self, forKey: .labels) ?? []
            help = try c.decodeIfPresent([Help].self, forKey: .help) ?? []
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        }
    }

    public let format: String
    public let ok: Bool
    public let diagnostics: [Diagnostic]

    /// True when any diagnostic has severity `error`.
    public var hasErrors: Bool { diagnostics.contains { $0.isError } }

    enum CodingKeys: String, CodingKey { case format, ok, diagnostics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        try FormatError.require(format, name: "synod-check")
        diagnostics = try c.decodeIfPresent([Diagnostic].self, forKey: .diagnostics) ?? []
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? diagnostics.isEmpty
    }

    /// Reads a `synod check --json` document.
    public static func parse(_ data: Data) throws -> CheckReport {
        do {
            return try JSONDecoder().decode(CheckReport.self, from: data)
        } catch let e as DecodingError {
            throw FormatError.malformed("check report: \(e.localizedDescription)")
        }
    }
}
