import Foundation

/// Line 1 of `trace.jsonl`.
public struct TraceHeader: Sendable, Equatable {
    public let format: String
    /// Language version, e.g. `0.2`.
    public let synod: String
    public let seed: UInt64
    /// Import path of the main file's folder.
    public let program: String
    public let packages: [String]
}

/// A message of a `net.*` event.
public struct TraceMessage: Sendable, Equatable {
    public let id: Int
    /// Package-qualified record type, e.g. `paxos.Prepare`.
    public let type: String
    public let fields: [StateField]

    /// `paxos.Prepare{number 101}`.
    public var display: String { SynodValue.record(type: type, fields: fields).display }
}

/// A message in flight: who sent it to whom.
public struct TraceEnvelope: Sendable, Equatable {
    public let msg: TraceMessage
    public let from: String
    public let to: String
}

/// The typed part of a trace event, for the kinds of `04-formats.md`.
public enum TracePayload: Sendable, Equatable {
    case started
    case ended(reason: String)
    case added(runs: [String], state: [StateField])
    case restarted(runs: [String], state: [StateField])
    case removed
    case crashed
    case changed(field: String, old: SynodValue, new: SynodValue)
    case injected(record: SynodValue)
    case fired
    case broken(rule: String)
    case emitted(record: SynodValue)
    case failed(code: String, message: String, pos: String?)
    case sent(TraceEnvelope)
    case arrived(TraceEnvelope)
    case dropped(TraceEnvelope, reason: String)
    case partitioned(a: [String], b: [String])
    case healed
    case written(key: String)
    /// A kind this build does not know; its keys are in `TraceEvent.extra`.
    case unknown
}

/// One trace line.
public struct TraceEvent: Sendable, Equatable {
    public let seq: Int
    /// Simulated time in microseconds.
    public let t: Int64
    /// The event kind, e.g. `sim.Changed`; open, so new kinds do not break readers.
    public let ev: String
    /// The node the event is about; nil for `null` or no node (`sim.Emitted` from main is nobody).
    public let node: String?
    public let payload: TracePayload
    /// Keys no typed payload consumed, in file order.
    public let extra: [JSONMember]

    public var time: SimTime { SimTime(microseconds: t) }
}

/// A parsed `trace.jsonl`.
public struct Trace: Sendable {
    public let header: TraceHeader
    public let events: [TraceEvent]

    /// Parses a whole trace file; rejects a major version other than 1.
    public static func parse(_ data: Data) throws -> Trace {
        var header: TraceHeader?
        var events: [TraceEvent] = []
        var lineNo = 0
        var start = data.startIndex
        let end = data.endIndex
        while start < end {
            let nl = data[start..<end].firstIndex(of: 0x0A) ?? end
            lineNo += 1
            if nl > start {
                let slice = data[start..<nl]
                let json: JSONValue
                do { json = try JSONParser.parse(Data(slice)) } catch {
                    throw FormatError.malformed("trace line \(lineNo): \(error)")
                }
                if header == nil {
                    header = try parseHeader(json)
                } else {
                    events.append(try parseEvent(json, line: lineNo))
                }
            }
            start = nl < end ? data.index(after: nl) : end
        }
        guard let header else { throw FormatError.malformed("empty trace") }
        return Trace(header: header, events: events)
    }

    static func parseHeader(_ j: JSONValue) throws -> TraceHeader {
        guard let format = j["format"]?.stringValue else { throw FormatError.malformed("trace header has no format") }
        try FormatError.require(format, name: "synod-trace")
        return TraceHeader(
            format: format,
            synod: j["synod"]?.stringValue ?? "",
            seed: j["seed"]?.uint64Value ?? 0,
            program: j["program"]?.stringValue ?? "",
            packages: (j["packages"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    static func parseEvent(_ j: JSONValue, line: Int) throws -> TraceEvent {
        guard let members = j.members, let seq = j["seq"]?.int64Value, let ev = j["ev"]?.stringValue else {
            throw FormatError.malformed("trace line \(line): not an event")
        }
        let t = j["t"]?.int64Value ?? 0
        let node = j["node"]?.stringValue
        var used: Set<String> = ["seq", "t", "ev", "node"]

        func take(_ key: String) -> JSONValue? {
            used.insert(key)
            return j[key]
        }
        func value(_ key: String) -> SynodValue { SynodValue(json: take(key) ?? .null) }
        func fields(_ key: String) -> [StateField] {
            (take(key)?.members ?? []).map { StateField(name: $0.key, value: SynodValue(json: $0.value, inRecord: true)) }
        }
        func strings(_ key: String) -> [String] { (take(key)?.arrayValue ?? []).compactMap(\.stringValue) }
        func envelope() -> TraceEnvelope {
            let m = take("msg")
            let msg = TraceMessage(
                id: Int(m?["id"]?.int64Value ?? 0),
                type: m?["type"]?.stringValue ?? "",
                fields: (m?["fields"]?.members ?? []).map { StateField(name: $0.key, value: SynodValue(json: $0.value, inRecord: true)) })
            return TraceEnvelope(msg: msg, from: take("from")?.stringValue ?? "", to: take("to")?.stringValue ?? "")
        }

        let payload: TracePayload
        switch ev {
        case "sim.Started": payload = .started
        case "sim.Ended": payload = .ended(reason: take("reason")?.stringValue ?? "")
        case "sim.Added": payload = .added(runs: strings("runs"), state: fields("state"))
        case "sim.Restarted": payload = .restarted(runs: strings("runs"), state: fields("state"))
        case "sim.Removed": payload = .removed
        case "sim.Crashed": payload = .crashed
        case "sim.Changed":
            payload = .changed(field: take("field")?.stringValue ?? "", old: value("old"), new: value("new"))
        case "sim.Injected": payload = .injected(record: value("record"))
        case "sim.Fired": payload = .fired
        case "sim.Broken": payload = .broken(rule: take("rule")?.stringValue ?? "")
        case "sim.Emitted": payload = .emitted(record: value("record"))
        case "sim.Failed":
            payload = .failed(code: take("code")?.stringValue ?? "", message: take("message")?.stringValue ?? "", pos: take("pos")?.stringValue)
        case "net.Sent": payload = .sent(envelope())
        case "net.Arrived": payload = .arrived(envelope())
        case "net.Dropped":
            let e = envelope()
            payload = .dropped(e, reason: take("reason")?.stringValue ?? "")
        case "net.Partitioned": payload = .partitioned(a: strings("a"), b: strings("b"))
        case "net.Healed": payload = .healed
        case "disk.Written": payload = .written(key: take("key")?.stringValue ?? "")
        default: payload = .unknown
        }
        let extra = members.filter { !used.contains($0.key) }
        return TraceEvent(seq: Int(seq), t: t, ev: ev, node: node, payload: payload, extra: extra)
    }
}

extension TraceEvent {
    /// The event as one line in the style of `synod run --summary`, e.g.
    /// `sim.Changed raft.Role of n3 from "follower" to "candidate"`.
    public var summaryLine: String {
        let who = node ?? "nobody"
        func pair(_ e: TraceEnvelope) -> String { "#\(e.msg.id) \(e.msg.display) from \(e.from) to \(e.to)" }
        func state(_ s: [StateField]) -> String { s.map { "\($0.name) \($0.value.display)" }.joined(separator: ", ") }
        func nodeList(_ l: [String]) -> String { "{" + l.joined(separator: ", ") + "}" }
        func runsText(_ runs: [String]) -> String {
            let names = runs.filter { !$0.hasPrefix("std/") }.map { String($0.split(separator: "/").last ?? "") }
            let all = names.isEmpty ? runs.map { String($0.split(separator: "/").last ?? "") } : names
            return all.joined(separator: ", ")
        }
        switch payload {
        case .ended(let r): return "sim.Ended \(r)"
        case .added(let runs, let st), .restarted(let runs, let st):
            var s = "\(ev) \(who) runs \(runsText(runs))"
            if !st.isEmpty { s += ": " + state(st) }
            return s
        case .changed(let f, let o, let n): return "sim.Changed \(f) of \(who) from \(o.display) to \(n.display)"
        case .injected(let r): return "sim.Injected \(r.display) into \(who)"
        case .emitted(let r): return "sim.Emitted \(r.display) by \(who)"
        case .broken(let rule): return "sim.Broken \(rule)"
        case .failed(let c, let m, _): return "sim.Failed \(c): \(m)"
        case .sent(let e): return "net.Sent " + pair(e)
        case .arrived(let e): return "net.Arrived " + pair(e)
        case .dropped(let e, let r): return "net.Dropped \(pair(e)) (\(r))"
        case .partitioned(let a, let b): return "net.Partitioned \(nodeList(a)) from \(nodeList(b))"
        case .written(let k): return "disk.Written \(SynodValue.text(k).display) on \(who)"
        case .started, .removed, .crashed, .fired, .healed, .unknown:
            return node != nil ? "\(ev) \(who)" : ev
        }
    }
}
