import Foundation

/// A source position `file:line:col`.
public struct SourcePos: Sendable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let col: Int
    public init(file: String, line: Int, col: Int) {
        self.file = file
        self.line = line
        self.col = col
    }

    public var description: String { "\(file):\(line):\(col)" }

    /// Parses `raft/raft.synod:12:5`.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) else { return nil }
        self.init(file: parts.dropLast(2).joined(separator: ":"), line: l, col: c)
    }
}

/// A run fault or a look fault: `failed at 2s: raft/raft.synod:12:5: error[index-range]: message`.
public struct RunFault: Sendable, Equatable {
    public let time: SimTime
    /// Nil for faults without a position (`time-limit`).
    public let pos: SourcePos?
    public let code: String
    public let message: String
}

/// An `always` rule that broke: `broken at 90ms (2 times): paxos/paxos.synod:109: always ...`.
public struct BrokenRule: Sendable, Equatable {
    public let time: SimTime
    public let count: Int
    public let rule: String
}

/// What `synod run` printed to stdout (short style), parsed. See `internal/pipeline/run.go`.
public struct RunStatus: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case ok(seed: UInt64, reason: String, end: SimTime, nodes: Int, events: Int, destination: String)
        case failed(RunFault)
    }

    public enum Scene: Sendable, Equatable {
        /// `length` is the compiler's text, e.g. `147.98s`.
        case ok(length: String, shapes: Int, destination: String)
        case lookFailed(RunFault)
    }

    public var result: Result?
    public var broken: [BrokenRule] = []
    public var scene: Scene?
    /// Lines the parser did not recognize.
    public var unparsed: [String] = []
    /// The text parsed.
    public var text: String

    /// The run fault, if the run failed.
    public var fault: RunFault? {
        if case .failed(let f) = result { return f }
        return nil
    }

    /// The look fault, if the look failed.
    public var lookFault: RunFault? {
        if case .lookFailed(let f) = scene { return f }
        return nil
    }

    /// True when the text held at least one recognized status line.
    public var isRecognized: Bool { result != nil || scene != nil || !broken.isEmpty }

    /// Parses the stdout of `synod run`.
    public static func parse(_ text: String) -> RunStatus { RunStatusParser.parse(text) }
}

/// Parser for the status lines of `synod run`.
public enum RunStatusParser {
    public static func parse(_ text: String) -> RunStatus {
        var st = RunStatus(text: text)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("ok seed "), let r = parseOK(line) {
                st.result = r
            } else if line.hasPrefix("failed at "), let f = parseFault(String(line.dropFirst("failed at ".count))) {
                st.result = .failed(f)
            } else if line.hasPrefix("look failed at "), let f = parseFault(String(line.dropFirst("look failed at ".count))) {
                st.scene = .lookFailed(f)
            } else if line.hasPrefix("broken at "), let b = parseBroken(line) {
                st.broken.append(b)
            } else if line.hasPrefix("scene "), let s = parseScene(line) {
                st.scene = s
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                st.unparsed.append(line)
            }
        }
        return st
    }

    /// `ok seed 3: stop at 8s, 5 nodes, 2197 events -> out/trace.jsonl`
    static func parseOK(_ line: String) -> RunStatus.Result? {
        let rest = line.dropFirst("ok seed ".count)
        guard let colon = rest.range(of: ": "), let seed = UInt64(rest[..<colon.lowerBound]) else { return nil }
        let tail = rest[colon.upperBound...]
        guard let at = tail.range(of: " at ") else { return nil }
        let reason = String(tail[..<at.lowerBound])
        let parts = tail[at.upperBound...].split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let us = FormatTime.parse(parts[0]),
            let nodes = leadingInt(parts[1]),
            let arrow = parts[2].range(of: " -> "), let events = leadingInt(parts[2])
        else { return nil }
        return .ok(seed: seed, reason: reason, end: SimTime(microseconds: us), nodes: nodes, events: events,
                   destination: String(parts[2][arrow.upperBound...]))
    }

    /// `2s: raft/raft.synod:12:5: error[code]: message` (the position is optional).
    static func parseFault(_ rest: String) -> RunFault? {
        guard let sep = rest.range(of: ": "), let us = FormatTime.parse(String(rest[..<sep.lowerBound])) else { return nil }
        var tail = String(rest[sep.upperBound...])
        var pos: SourcePos?
        if !tail.hasPrefix("error["), let e = tail.range(of: ": error[") {
            pos = SourcePos(String(tail[..<e.lowerBound]))
            tail = String(tail[e.lowerBound...].dropFirst(2))
        }
        guard tail.hasPrefix("error["), let close = tail.range(of: "]: ") else { return nil }
        let code = String(tail[tail.index(tail.startIndex, offsetBy: 6)..<close.lowerBound])
        return RunFault(time: SimTime(microseconds: us), pos: pos, code: code, message: String(tail[close.upperBound...]))
    }

    /// `broken at 90ms (2 times): rule`
    static func parseBroken(_ line: String) -> BrokenRule? {
        let rest = line.dropFirst("broken at ".count)
        guard let open = rest.range(of: " ("), let us = FormatTime.parse(String(rest[..<open.lowerBound])),
            let close = rest.range(of: "): ", range: open.upperBound..<rest.endIndex),
            let n = leadingInt(String(rest[open.upperBound..<close.lowerBound]))
        else { return nil }
        return BrokenRule(time: SimTime(microseconds: us), count: n, rule: String(rest[close.upperBound...]))
    }

    /// `scene 147.98s, 1928 shapes -> out/scene.json`
    static func parseScene(_ line: String) -> RunStatus.Scene? {
        let rest = line.dropFirst("scene ".count)
        let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].hasSuffix("s"), let arrow = parts[1].range(of: " -> "), let shapes = leadingInt(parts[1]) else { return nil }
        return .ok(length: parts[0], shapes: shapes, destination: String(parts[1][arrow.upperBound...]))
    }

    private static func leadingInt<S: StringProtocol>(_ s: S) -> Int? {
        Int(s.prefix { $0.isNumber })
    }
}
