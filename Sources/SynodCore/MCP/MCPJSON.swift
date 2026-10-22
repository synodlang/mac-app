import Foundation

/// Compact, order-preserving JSON output and small builders for MCP messages.
public enum MCPJSON {
    /// One-line JSON text of `value`. Object keys keep their order; there is never a raw newline in the output.
    public static func encode(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d, let raw):
            if !raw.isEmpty {
                out += raw
            } else if d == d.rounded(), abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += "," }
                writeString(m.key, into: &out)
                out += ":"
                write(m.value, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Builders

    static func obj(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
    }

    static func int(_ i: Int) -> JSONValue { .number(Double(i), raw: String(i)) }
    static func str(_ s: String) -> JSONValue { .string(s) }
    static func optStr(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    static func optInt(_ i: Int?) -> JSONValue { i.map { int($0) } ?? .null }
}
