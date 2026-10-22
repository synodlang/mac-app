import Foundation

/// Whether a node is running, crashed (state kept) or removed.
public enum NodeStatus: String, Sendable, Equatable {
    case up, crashed, removed
}

/// A node's exported state after some trace event.
public struct NodeState: Sendable, Equatable {
    /// Exported fields in declaration order, `pkg.Field`.
    public var fields: [StateField]
    /// Import paths of the packages the node runs.
    public var runs: [String]
    public var status: NodeStatus
    /// For each field, the seq of the event that last set it.
    public var lastChange: [String: Int]

    /// The value of a field such as `raft.Role`.
    public func value(of field: String) -> SynodValue? {
        fields.first { $0.name == field }?.value
    }

    /// The fields that the event with this `seq` set (for a "changed at this fact" highlight).
    public func changedFields(atSeq seq: Int) -> Set<String> {
        Set(lastChange.filter { $0.value == seq }.keys)
    }
}

/// Replay and lookup over a run: the trace events together with the scene's `trace` map.
///
/// `factAt` mirrors the player's lookup so the host and the stage agree on the current fact.
public struct TraceIndex: Sendable {
    public let header: TraceHeader
    public let events: [TraceEvent]
    /// Nodes in the order they were first added (or first seen).
    public let nodes: [String]
    /// The scene's `trace` entries, in file order (sorted by `at`).
    public let entries: [SceneSummary.TraceEntry]

    private let seqs: [Int]
    private let entryAtBySeq: [Int: Double]
    private let checkpoints: [[String: NodeState]]
    static let checkpointInterval = 256

    public init(trace: Trace, scene: SceneSummary) {
        self.init(header: trace.header, events: trace.events, entries: scene.trace)
    }

    public init(header: TraceHeader, events: [TraceEvent], entries: [SceneSummary.TraceEntry]) {
        self.header = header
        self.events = events
        self.entries = entries
        seqs = events.map(\.seq)
        entryAtBySeq = Dictionary(entries.map { ($0.seq, $0.at) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var seen: Set<String> = []
        var states: [String: NodeState] = [:]
        var cps: [[String: NodeState]] = [[:]]
        for (i, e) in events.enumerated() {
            if let n = e.node, !seen.contains(n) {
                seen.insert(n)
                order.append(n)
            }
            if let n = e.node { Self.apply(e, to: &states[n]) }
            if (i + 1) % Self.checkpointInterval == 0 { cps.append(states) }
        }
        nodes = order
        checkpoints = cps
    }

    // MARK: Facts and time

    /// The last trace entry with `at <= t`, or nil before the first (same rule as the player).
    public func factAt(_ t: Double) -> SceneSummary.TraceEntry? {
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if entries[mid].at <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : entries[lo - 1]
    }

    /// The presentation time (ms) of the scene entry for `seq`, or nil if the scene has none.
    public func timeOfSeq(_ seq: Int) -> Double? { entryAtBySeq[seq] }

    /// The event with exactly this seq.
    public func event(seq: Int) -> TraceEvent? {
        let i = lastIndex(atOrBefore: seq)
        return i >= 0 && events[i].seq == seq ? events[i] : nil
    }

    /// The simulated time of the event with this seq (for the simulated-time display).
    public func simTime(ofSeq seq: Int) -> SimTime? { event(seq: seq)?.time }

    /// Index of the last event with `seq <= x`, or -1.
    private func lastIndex(atOrBefore x: Int) -> Int {
        var lo = 0
        var hi = seqs.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if seqs[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    // MARK: State

    /// The state of `node` after the event with the last seq at or before `atSeq`; nil before the
    /// node's first `sim.Added`. Replays from the nearest checkpoint (every 256 events).
    public func state(of node: String, atSeq: Int) -> NodeState? {
        let idx = lastIndex(atOrBefore: atSeq)
        if idx < 0 { return nil }
        let c = min((idx + 1) / Self.checkpointInterval, checkpoints.count - 1)
        var s = checkpoints[c][node]
        var j = c * Self.checkpointInterval
        while j <= idx {
            if events[j].node == node { Self.apply(events[j], to: &s) }
            j += 1
        }
        return s
    }

    /// Replay from the first event; the reference the checkpointed `state` must equal.
    func naiveState(of node: String, atSeq: Int) -> NodeState? {
        var s: NodeState?
        for e in events where e.seq <= atSeq && e.node == node { Self.apply(e, to: &s) }
        return s
    }

    /// Applies `sim.Added`/`Restarted` (replace), `Changed` (set), `Crashed`, `Removed`.
    private static func apply(_ e: TraceEvent, to s: inout NodeState?) {
        switch e.payload {
        case .added(let runs, let state), .restarted(let runs, let state):
            var last: [String: Int] = [:]
            for f in state { last[f.name] = e.seq }
            s = NodeState(fields: state, runs: runs, status: .up, lastChange: last)
        case .changed(let field, _, let new):
            guard var cur = s else { return }
            if let i = cur.fields.firstIndex(where: { $0.name == field }) {
                cur.fields[i] = StateField(name: field, value: new)
            } else {
                cur.fields.append(StateField(name: field, value: new))
            }
            cur.lastChange[field] = e.seq
            s = cur
        case .crashed:
            s?.status = .crashed
        case .removed:
            s?.status = .removed
        default:
            break
        }
    }

    // MARK: Windows and lines

    /// The events around `seq` (at or before it): `radius` before and after, clamped to the trace.
    /// With `node`, only events of that node (as the subject, sender or receiver) are counted.
    public func window(around seq: Int, radius: Int = 40, node: String? = nil) -> [TraceEvent] {
        let r = max(0, radius)
        guard let node else {
            let i = max(lastIndex(atOrBefore: seq), 0)
            guard !events.isEmpty else { return [] }
            return Array(events[max(0, i - r)...min(events.count - 1, i + r)])
        }
        let own = events.filter { e in
            if e.node == node { return true }
            switch e.payload {
            case .sent(let m), .arrived(let m), .dropped(let m, _): return m.from == node || m.to == node
            default: return false
            }
        }
        guard !own.isEmpty else { return [] }
        var lo = 0
        var hi = own.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if own[mid].seq <= seq { lo = mid + 1 } else { hi = mid }
        }
        let center = max(lo - 1, 0)
        return Array(own[max(0, center - r)...min(own.count - 1, center + r)])
    }

    /// One trace line of the event in the style of the run summary.
    public func oneLine(_ event: TraceEvent) -> String { event.summaryLine }
}
