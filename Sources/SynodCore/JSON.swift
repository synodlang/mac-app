import Foundation

/// One member of a JSON object; objects keep their key order (the formats depend on it).
public struct JSONMember: Sendable, Equatable {
    public let key: String
    public let value: JSONValue
    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A parsed JSON value that keeps object key order and the raw text of numbers.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A number with its source text, so 64-bit integers survive.
    case number(Double, raw: String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    /// The value of `key` in an object, or nil.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let d, _) = self { return d }
        return nil
    }

    /// An integer number (exact for the raw text when it is one).
    public var int64Value: Int64? {
        guard case .number(let d, let raw) = self else { return nil }
        if let i = Int64(raw) { return i }
        return d.isFinite && d == d.rounded() && abs(d) < 9.2e18 ? Int64(d) : nil
    }

    public var uint64Value: UInt64? {
        guard case .number(let d, let raw) = self else { return nil }
        if let i = UInt64(raw) { return i }
        return d.isFinite && d >= 0 && d == d.rounded() && d < 1.8e19 ? UInt64(d) : nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var members: [JSONMember]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// A JSON syntax error.
public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "invalid JSON at byte \(offset): \(message)" }
}

/// A small order-preserving JSON parser for trace lines and values.
public enum JSONParser {
    /// Parses one JSON document.
    public static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var p = Parser(bytes: raw.bindMemory(to: UInt8.self))
            return try p.document()
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        func fail(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func document() throws -> JSONValue {
            skipSpace()
            let v = try value(depth: 0)
            skipSpace()
            if i != bytes.count { throw fail("trailing characters") }
            return v
        }

        mutating func value(depth: Int) throws -> JSONValue {
            if depth > 512 { throw fail("nesting too deep") }
            skipSpace()
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for c in word.utf8 {
                guard i < bytes.count, bytes[i] == c else { throw fail("bad literal") }
                i += 1
            }
        }

        mutating func number() throws -> JSONValue {
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                    i += 1
                } else { break }
            }
            guard i > start else { throw fail("unexpected character") }
            let raw = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            guard let d = Double(raw) else { throw fail("bad number") }
            return .number(d, raw: raw)
        }

        mutating func string() throws -> String {
            i += 1  // opening quote
            let start = i
            var hasEscape = false
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                if bytes[i] == UInt8(ascii: "\\") { hasEscape = true; i += 1 }
                i += 1
            }
            guard i < bytes.count else { throw fail("unterminated string") }
            let slice = UnsafeBufferPointer(rebasing: bytes[start..<i])
            i += 1
            if !hasEscape { return String(decoding: slice, as: UTF8.self) }
            return try unescape(slice)
        }

        func unescape(_ s: UnsafeBufferPointer<UInt8>) throws -> String {
            var out: [UInt8] = []
            out.reserveCapacity(s.count)
            var k = 0
            func hex4(_ at: Int) throws -> UInt32 {
                guard at + 4 <= s.count else { throw fail("bad \\u escape") }
                var v: UInt32 = 0
                for j in at..<at + 4 {
                    guard let d = Character(UnicodeScalar(s[j])).hexDigitValue else { throw fail("bad \\u escape") }
                    v = v * 16 + UInt32(d)
                }
                return v
            }
            while k < s.count {
                let c = s[k]
                if c != UInt8(ascii: "\\") { out.append(c); k += 1; continue }
                k += 1
                guard k < s.count else { throw fail("bad escape") }
                let e = s[k]
                k += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4(k)
                    k += 4
                    if code >= 0xD800, code < 0xDC00, k + 6 <= s.count, s[k] == UInt8(ascii: "\\"), s[k + 1] == UInt8(ascii: "u") {
                        let low = try hex4(k + 2)
                        if low >= 0xDC00, low < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            k += 6
                        }
                    }
                    let scalar = UnicodeScalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var members: [JSONMember] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let key = try string()
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
                i += 1
                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected , or }")
            }
        }
    }
}

/// A file with a format version this build cannot read, or that is malformed.
public enum FormatError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The `format` value names a major version this build does not read.
    case unsupported(format: String, expected: String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unsupported(let f, let e): return "unsupported format \"\(f)\" (this app reads \(e)/1)"
        case .malformed(let m): return m
        }
    }

    public var errorDescription: String? { description }

    /// Throws `unsupported` unless `format` is `<name>/1` or a later minor of major 1 (`<name>/1.x`).
    static func require(_ format: String, name: String) throws {
        let prefix = name + "/"
        guard format.hasPrefix(prefix) else { throw FormatError.unsupported(format: format, expected: name) }
        let major = format.dropFirst(prefix.count).prefix { $0 != "." }
        guard major == "1" else { throw FormatError.unsupported(format: format, expected: name) }
    }
}
