import Foundation

/// One named field of a record or of a node's exported state.
public struct StateField: Sendable, Equatable {
    public let name: String
    public let value: SynodValue
    public init(name: String, value: SynodValue) {
        self.name = name
        self.value = value
    }
}

/// One entry of a Synod map.
public struct MapEntry: Sendable, Equatable {
    public let key: SynodValue
    public let value: SynodValue
    public init(key: SynodValue, value: SynodValue) {
        self.key = key
        self.value = value
    }
}

/// A Synod value as written in a trace (formats `04-formats.md`, "Value encoding").
public indirect enum SynodValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    /// Microseconds of simulated time.
    case time(Int64)
    /// A node name such as `n3`; nil is `nobody`.
    case node(String?)
    case list([SynodValue])
    case map([MapEntry])
    /// A record such as `paxos.Prepare{number 101}`; `type` is already package-qualified.
    case record(type: String, fields: [StateField])
    /// An unexported field the trace hides (`…`).
    case opaque

    /// Decodes a trace value. `inRecord` makes the text `…` an opaque field.
    public init(json: JSONValue, inRecord: Bool = false) {
        switch json {
        case .string(let s): self = (inRecord && s == "…") ? .opaque : .text(s)
        case .number(let d, _): self = .number(d)
        case .bool(let b): self = .bool(b)
        case .null: self = .node(nil)
        case .array(let a): self = .list(a.map { SynodValue(json: $0) })
        case .object(let members):
            guard let first = members.first else { self = .map([]); return }
            switch first.key {
            case "time" where members.count == 1:
                self = .time(first.value.int64Value ?? 0)
            case "node" where members.count == 1:
                self = .node(first.value.stringValue)
            case "map" where members.count == 1:
                var entries: [MapEntry] = []
                for pair in first.value.arrayValue ?? [] {
                    if let kv = pair.arrayValue, kv.count == 2 {
                        entries.append(MapEntry(key: SynodValue(json: kv[0]), value: SynodValue(json: kv[1])))
                    }
                }
                self = .map(entries)
            case "type":
                let type = first.value.stringValue ?? ""
                var fields: [StateField] = []
                for m in json["fields"]?.members ?? [] {
                    fields.append(StateField(name: m.key, value: SynodValue(json: m.value, inRecord: true)))
                }
                self = .record(type: type, fields: fields)
            default:
                self = .opaque
            }
        }
    }

    /// Synod text for the value: `"quoted"`, `nobody`, `{a, b}`, `{k: v}`, `pkg.Type{field v}`, `2s`.
    public var display: String {
        var out = ""
        write(&out)
        return out
    }

    private func write(_ out: inout String) {
        switch self {
        case .text(let s):
            out += "\""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                default: out.unicodeScalars.append(ch)
                }
            }
            out += "\""
        case .number(let d): out += FormatNumber.string(d)
        case .bool(let b): out += b ? "true" : "false"
        case .time(let us): out += FormatTime.string(microseconds: us)
        case .node(let n): out += n ?? "nobody"
        case .list(let items):
            out += "{"
            for (i, v) in items.enumerated() {
                if i > 0 { out += ", " }
                v.write(&out)
            }
            out += "}"
        case .map(let entries):
            out += "{"
            for (i, e) in entries.enumerated() {
                if i > 0 { out += ", " }
                e.key.write(&out)
                out += ": "
                e.value.write(&out)
            }
            out += "}"
        case .record(let type, let fields):
            out += type + "{"
            for (i, f) in fields.enumerated() {
                if i > 0 { out += ", " }
                out += f.name + " "
                f.value.write(&out)
            }
            out += "}"
        case .opaque: out += "…"
        }
    }
}
