import Foundation

// Break it (decisions 85 and 86): a click on the stage becomes one `after <T>` block of ordinary
// Synod at the end of `define main`. This file is the pure part: which actions a fact offers, the
// plan and its text, the edit of the main file, and the check of the new run.

/// The canonical duration literal of `microseconds`: `0s`, `6001ms`, `7s`, `20.431ms` (spec/10).
public func durationLiteral(microseconds: Int64) -> String {
    FormatTime.string(microseconds: microseconds)
}

/// What a click asks for.
public enum BreakItAction: Sendable, Equatable {
    case crash(node: String)
    case restart(node: String)
    /// The selected nodes against every other node that is not removed.
    case partition(selected: [String])
    case heal
    /// Drop the message with this trace id.
    case dropMessage(id: Int)
}

/// Why an action cannot be planned.
public enum BreakItError: Error, Equatable, LocalizedError {
    case unknownNode(String)
    case needsBothSides
    case unknownMessage(Int)
    /// An earlier message of the same type on the same link was sent at the same instant.
    case cannotSingleOut
    case noMainBlock

    public var errorDescription: String? {
        switch self {
        case .unknownNode(let n): return "Node \(n) does not exist at that time"
        case .needsBothSides: return "A partition needs at least one node on each side"
        case .unknownMessage(let id): return "Message #\(id) is not in the trace"
        case .cannotSingleOut: return "Cannot single out this message"
        case .noMainBlock: return "The main file has no define main"
        }
    }
}

/// The fact to look for in the new trace.
public enum BreakItExpectation: Sendable, Equatable {
    case crashed(node: String, at: Int64)
    case restarted(node: String, at: Int64)
    case partitioned(at: Int64, a: [String], b: [String])
    case healed(at: Int64)
    /// A `net.Dropped` (reason `targeted`) of a message of this unqualified type on this link,
    /// sent at `sentAt`.
    case dropped(type: String, from: String, to: String, sentAt: Int64)
}

/// One planned edit.
public struct BreakItPlan: Sendable, Equatable {
    public let action: BreakItAction
    /// The time of the `after` block, in microseconds.
    public let time: Int64
    /// The statement with its trailing comment, e.g. `sim.Crash (item 4 of sim.Nodes) # n5`.
    public let statement: String
    /// Import paths the statement needs, sorted: `std/net`, `std/sim`.
    public let imports: [String]
    public let expectation: BreakItExpectation

    /// `6001ms`, `0s`, `20.431ms`.
    public var timeLiteral: String { durationLiteral(microseconds: time) }

    /// The two lines appended to `define main`, without a trailing newline.
    public var blockLines: [String] { ["  after \(timeLiteral)", "    \(statement)"] }

    /// The same plan at another time (the sheet lets the user change `T` for crash, restart,
    /// partition and heal; the drop keeps the message's send time, so it ignores this).
    public func retimed(to t: Int64) -> BreakItPlan {
        switch action {
        case .dropMessage: return self
        default:
            let exp: BreakItExpectation
            switch expectation {
            case .crashed(let n, _): exp = .crashed(node: n, at: t)
            case .restarted(let n, _): exp = .restarted(node: n, at: t)
            case .partitioned(_, let a, let b): exp = .partitioned(at: t, a: a, b: b)
            case .healed: exp = .healed(at: t)
            case .dropped: exp = expectation
            }
            return BreakItPlan(action: action, time: t, statement: statement, imports: imports, expectation: exp)
        }
    }
}

/// What a node offers at the current fact.
public enum BreakItNodeOffer: Sendable, Equatable {
    case crash, restart, none
}

/// What a message dot offers.
public enum BreakItDropOffer: Sendable, Equatable {
    case available
    /// Disabled, with the reason to show.
    case disabled(String)
    case unknown
}

/// Plans Break it actions from a run's trace.
///
/// A node is named `(item i of sim.Nodes)` where `i` is its 0-based index among the nodes added
/// and not removed before `T`, in creation order. Statements at `T` run before node events at `T`,
/// so only events strictly before `T` count; they are the same in the re-run.
public struct BreakItPlanner: Sendable {
    public let index: TraceIndex
    private let sends: [Int: TraceEvent]
    private let sendsByLink: [String: [TraceEvent]]

    public init(index: TraceIndex) {
        self.index = index
        var byID: [Int: TraceEvent] = [:]
        var byLink: [String: [TraceEvent]] = [:]
        for e in index.events {
            if case .sent(let env) = e.payload {
                byID[env.msg.id] = e
                byLink[Self.linkKey(env), default: []].append(e)
            }
        }
        sends = byID
        sendsByLink = byLink
    }

    private static func linkKey(_ env: TraceEnvelope) -> String { "\(env.from)\u{1}\(env.to)\u{1}\(env.msg.type)" }

    /// `Prepare` for `paxos.Prepare` (the spelling `net.DropNext` takes).
    public static func unqualified(_ type: String) -> String {
        type.split(separator: ".").last.map(String.init) ?? type
    }

    // MARK: Time and nodes

    /// The first whole millisecond strictly after the fact `factSeq`'s time (`0` with no fact).
    public func defaultTime(factSeq: Int?) -> Int64 {
        guard let s = factSeq, let e = index.event(seq: s) else { return 0 }
        return (e.t / 1000 + 1) * 1000
    }

    /// `sim.Nodes` at `T`: nodes added and not removed by events strictly before `T`, in creation order.
    public func nodes(at time: Int64) -> [String] {
        var list: [String] = []
        for e in index.events {
            if e.t >= time { break }
            switch e.payload {
            case .added:
                if let n = e.node, !list.contains(n) { list.append(n) }
            case .removed:
                if let n = e.node { list.removeAll { $0 == n } }
            default: break
            }
        }
        return list
    }

    /// Crash for a node that is up at the fact, Restart for a crashed one.
    public func offer(forNode node: String, factSeq: Int?) -> BreakItNodeOffer {
        guard let s = factSeq, let st = index.state(of: node, atSeq: s) else { return .none }
        switch st.status {
        case .up: return .crash
        case .crashed: return .restart
        case .removed: return .none
        }
    }

    /// Whether a partition is active after the fact (Heal is offered then).
    public func partitionActive(factSeq: Int?) -> Bool {
        guard let s = factSeq else { return false }
        var active = false
        for e in index.events {
            if e.seq > s { break }
            switch e.payload {
            case .partitioned: active = true
            case .healed: active = false
            default: break
            }
        }
        return active
    }

    /// Whether the message can be dropped on its own, and why not.
    public func offer(forMessage id: Int) -> BreakItDropOffer {
        guard let e = sends[id], case .sent(let env) = e.payload else { return .unknown }
        return hasEarlierTwin(e, env) ? .disabled(BreakItError.cannotSingleOut.errorDescription!) : .available
    }

    private func hasEarlierTwin(_ e: TraceEvent, _ env: TraceEnvelope) -> Bool {
        (sendsByLink[Self.linkKey(env)] ?? []).contains { $0.t == e.t && $0.seq < e.seq }
    }

    // MARK: Plans

    private static func ref(_ node: String, in list: [String]) throws -> String {
        guard let i = list.firstIndex(of: node) else { throw BreakItError.unknownNode(node) }
        return "(item \(i) of sim.Nodes)"
    }

    public func plan(_ action: BreakItAction, at time: Int64? = nil, factSeq: Int? = nil) throws -> BreakItPlan {
        let t = time ?? defaultTime(factSeq: factSeq)
        switch action {
        case .crash(let n):
            let list = nodes(at: t)
            return BreakItPlan(action: action, time: t, statement: "sim.Crash \(try Self.ref(n, in: list)) # \(n)",
                imports: ["std/sim"], expectation: .crashed(node: n, at: t))
        case .restart(let n):
            let list = nodes(at: t)
            return BreakItPlan(action: action, time: t, statement: "sim.Restart \(try Self.ref(n, in: list)) # \(n)",
                imports: ["std/sim"], expectation: .restarted(node: n, at: t))
        case .partition(let selected):
            let list = nodes(at: t)
            for n in selected where !list.contains(n) { throw BreakItError.unknownNode(n) }
            let one = list.filter { selected.contains($0) }
            let other = list.filter { !selected.contains($0) }
            guard !one.isEmpty, !other.isEmpty else { throw BreakItError.needsBothSides }
            func side(_ s: [String]) throws -> String { "{" + (try s.map { try Self.ref($0, in: list) }).joined(separator: ", ") + "}" }
            let st = "net.Partition \(try side(one)) from \(try side(other)) # \(one.joined(separator: ", ")) from \(other.joined(separator: ", "))"
            return BreakItPlan(action: action, time: t, statement: st, imports: ["std/net", "std/sim"],
                expectation: .partitioned(at: t, a: one, b: other))
        case .heal:
            return BreakItPlan(action: action, time: t, statement: "net.Heal", imports: ["std/net"], expectation: .healed(at: t))
        case .dropMessage(let id):
            guard let e = sends[id], case .sent(let env) = e.payload else { throw BreakItError.unknownMessage(id) }
            if hasEarlierTwin(e, env) { throw BreakItError.cannotSingleOut }
            let list = nodes(at: e.t)
            let type = Self.unqualified(env.msg.type)
            let st = "net.DropNext \"\(type)\" from \(try Self.ref(env.from, in: list)) to \(try Self.ref(env.to, in: list)) # \(env.from) to \(env.to)"
            return BreakItPlan(action: action, time: e.t, statement: st, imports: ["std/net", "std/sim"],
                expectation: .dropped(type: type, from: env.from, to: env.to, sentAt: e.t))
        }
    }
}

/// Edits the main file's text for a plan.
public enum MainEditor {
    /// The edits that append the plan's block to `define main` and add the missing `use` lines, in
    /// descending position order (apply them one after the other, as one undo group). Throws
    /// `BreakItError.noMainBlock` when the file has no `define main`.
    public static func edits(for plan: BreakItPlan, in text: String) throws -> [TextEdit] {
        let lines = Self.lines(of: text)
        guard let mainIdx = lines.firstIndex(where: { isDefineMain($0.text) }) else { throw BreakItError.noMainBlock }

        // The block ends at the last non-blank indented line before the next top-level line.
        var last = mainIdx
        var i = mainIdx + 1
        while i < lines.count {
            let l = lines[i].text
            if l.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if l.hasPrefix(" ") || l.hasPrefix("\t") { last = i; i += 1 } else { break }
        }
        var edits = [
            TextEdit(range: NSRange(location: lines[last].contentEnd, length: 0),
                replacement: "\n" + plan.blockLines.joined(separator: "\n"))
        ]

        // Missing imports, in byte order.
        var present: Set<String> = []
        var useLines: [(idx: Int, path: String)] = []
        for (n, l) in lines.enumerated() where l.text.hasPrefix("use ") {
            let p = l.text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            present.insert(p)
            useLines.append((n, p))
        }
        let missing = plan.imports.filter { !present.contains($0) }.sorted { bytesLess($0, $1) }
        // Group the new lines by anchor: before an existing use line, or after a line.
        enum Anchor: Equatable { case before(Int), after(Int) }
        var groups: [(Anchor, [String])] = []
        let header = lines.firstIndex { $0.text.hasPrefix("# package") } ?? 0
        for m in missing {
            let anchor: Anchor
            if let next = useLines.first(where: { bytesLess(m, $0.path) }) {
                anchor = .before(next.idx)
            } else {
                anchor = .after(useLines.last?.idx ?? header)
            }
            if let g = groups.last, g.0 == anchor { groups[groups.count - 1].1.append("use \(m)") } else { groups.append((anchor, ["use \(m)"])) }
        }
        for (anchor, newLines) in groups {
            switch anchor {
            case .before(let k):
                edits.append(TextEdit(range: NSRange(location: lines[k].start, length: 0), replacement: newLines.joined(separator: "\n") + "\n"))
            case .after(let k):
                edits.append(TextEdit(range: NSRange(location: lines[k].contentEnd, length: 0), replacement: "\n" + newLines.joined(separator: "\n")))
            }
        }
        return edits.sorted { $0.range.location > $1.range.location }
    }

    /// `text` with the plan applied.
    public static func apply(_ plan: BreakItPlan, to text: String) throws -> String {
        TextEdit.apply(try edits(for: plan, in: text), to: text)
    }

    struct Line {
        let text: String
        /// UTF-16 offsets: start of the line and the end of its content (before `\n`).
        let start: Int
        let contentEnd: Int
    }

    static func lines(of text: String) -> [Line] {
        let ns = text as NSString
        var result: [Line] = []
        var start = 0
        let n = ns.length
        while start <= n {
            var end = start
            while end < n && ns.character(at: end) != 10 { end += 1 }
            result.append(Line(text: ns.substring(with: NSRange(location: start, length: end - start)), start: start, contentEnd: end))
            if end >= n { break }
            start = end + 1
        }
        return result
    }

    private static func isDefineMain(_ line: String) -> Bool {
        guard line.hasPrefix("define main") else { return false }
        let rest = line.dropFirst("define main".count)
        return rest.isEmpty || rest.first == " " || rest.first == "#"
    }

    private static func bytesLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}

/// A rule's source line from `sim.Broken`'s `rule` text (`paxos/paxos.synod:109: always …`).
public struct RuleLocation: Sendable, Equatable {
    public let file: String
    public let line: Int

    public init?(rule: String) {
        // `<path>:<line>: <text>`; the path may contain colons only on exotic systems, so split from the left.
        guard let sep = rule.range(of: ": ") else { return nil }
        let head = rule[..<sep.lowerBound]
        guard let colon = head.lastIndex(of: ":"), let n = Int(head[head.index(after: colon)...]), n >= 1 else { return nil }
        file = String(head[..<colon])
        line = n
    }
}

/// A rule broken in a run.
public struct BrokenFact: Sendable, Equatable {
    public let rule: String
    /// The first `sim.Broken` of the rule.
    public let seq: Int
    public let time: Int64
    public var location: RuleLocation? { RuleLocation(rule: rule) }
}

/// Checks a Break it run against its plan.
public enum BreakItVerifier {
    /// The `seq` of the event the plan's action produced in the new trace, or nil: "Break it had no effect".
    public static func verify(_ plan: BreakItPlan, in index: TraceIndex) -> Int? {
        verify(plan.expectation, in: index)
    }

    public static func verify(_ exp: BreakItExpectation, in index: TraceIndex) -> Int? {
        switch exp {
        case .crashed(let node, let t):
            return index.events.first { $0.t == t && $0.node == node && $0.payload == .crashed }?.seq
        case .restarted(let node, let t):
            return index.events.first { e in
                if case .restarted = e.payload { return e.t == t && e.node == node }
                return false
            }?.seq
        case .partitioned(let t, let a, let b):
            return index.events.first { e in
                guard case .partitioned(let x, let y) = e.payload, e.t == t else { return false }
                return (Set(x) == Set(a) && Set(y) == Set(b)) || (Set(x) == Set(b) && Set(y) == Set(a))
            }?.seq
        case .healed(let t):
            return index.events.first { $0.t == t && $0.payload == .healed }?.seq
        case .dropped(let type, let from, let to, let sentAt):
            // The message ids of the new run: sent at `sentAt` on the link with the type.
            var ids: Set<Int> = []
            for e in index.events where e.t == sentAt {
                if case .sent(let env) = e.payload, env.from == from, env.to == to, BreakItPlanner.unqualified(env.msg.type) == type {
                    ids.insert(env.msg.id)
                }
            }
            return index.events.first { e in
                if case .dropped(let env, let reason) = e.payload { return reason == "targeted" && ids.contains(env.msg.id) }
                return false
            }?.seq
        }
    }

    /// Rules broken in `current` but not in `previous` (compared by their `rule` text), in order
    /// of their first `sim.Broken`.
    public static func newlyBroken(previous: TraceIndex?, current: TraceIndex) -> [BrokenFact] {
        func rules(_ i: TraceIndex) -> [BrokenFact] {
            var seen: Set<String> = []
            var out: [BrokenFact] = []
            for e in i.events {
                if case .broken(let r) = e.payload, seen.insert(r).inserted { out.append(BrokenFact(rule: r, seq: e.seq, time: e.t)) }
            }
            return out
        }
        let before = Set(previous.map(rules)?.map(\.rule) ?? [])
        return rules(current).filter { !before.contains($0.rule) }
    }
}
