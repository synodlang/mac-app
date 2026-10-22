import Foundation

/// The map between simulated time and presentation time of one run, used by Compare
/// (decision 87). Two runs share simulated time, not presentation time, so the right side of a
/// comparison seeks to `at(simTime: T)` where `T = simTime(atPresentation:)` of the left side.
///
/// The map is piecewise linear through the knots: (0, 0); for each distinct trace time `t`, the
/// largest scene slot (`at`) of the facts at `t`; and (end, duration), where `end` is the time of
/// `sim.Ended`, else of the last fact. Knots at one `t` are merged by taking the larger `at`, so
/// the map is a function; presentation values never decrease.
public struct SyncMap: Sendable, Equatable {
    public struct Knot: Sendable, Equatable {
        /// Simulated time in microseconds.
        public let t: Int64
        /// Presentation time in ms.
        public let at: Double
        public init(t: Int64, at: Double) {
            self.t = t
            self.at = at
        }
    }

    /// Strictly increasing in `t`, non-decreasing in `at`; never empty.
    public let knots: [Knot]

    /// A map from knots, which are sorted, merged at equal `t` and made monotone.
    public init(knots raw: [Knot]) {
        var sorted = raw.sorted { $0.t < $1.t }
        if sorted.isEmpty { sorted = [Knot(t: 0, at: 0)] }
        var merged: [Knot] = []
        var running = -Double.infinity
        for k in sorted {
            running = max(running, k.at)
            if let last = merged.last, last.t == k.t {
                merged[merged.count - 1] = Knot(t: k.t, at: running)
            } else {
                merged.append(Knot(t: k.t, at: running))
            }
        }
        knots = merged
    }

    /// Builds the map of a run from its trace and scene.
    public init(index: TraceIndex, duration: Double) {
        self.init(events: index.events, entries: index.entries, duration: duration)
    }

    public init(events: [TraceEvent], entries: [SceneSummary.TraceEntry], duration: Double) {
        let atBySeq = Dictionary(entries.map { ($0.seq, $0.at) }, uniquingKeysWith: { a, _ in a })
        var knots = [Knot(t: 0, at: 0)]
        var lastT: Int64 = 0
        var endT: Int64?
        var slot: [Int64: Double] = [:]
        var times: [Int64] = []
        for e in events {
            lastT = max(lastT, e.t)
            if case .ended = e.payload { endT = e.t }
            guard let at = atBySeq[e.seq] else { continue }
            if let cur = slot[e.t] {
                slot[e.t] = max(cur, at)
            } else {
                slot[e.t] = at
                times.append(e.t)
            }
        }
        for t in times { knots.append(Knot(t: t, at: slot[t]!)) }
        knots.append(Knot(t: endT ?? lastT, at: duration))
        self.init(knots: knots)
    }

    /// The last knot's simulated time.
    public var endTime: Int64 { knots[knots.count - 1].t }
    /// The last knot's presentation time (the scene duration).
    public var duration: Double { knots[knots.count - 1].at }

    /// The presentation time (ms) of a simulated time (µs), interpolated and clamped.
    public func at(simTime t: Double) -> Double {
        let first = knots[0]
        let last = knots[knots.count - 1]
        if t <= Double(first.t) { return first.at }
        if t >= Double(last.t) { return last.at }
        // First knot with knot.t >= t.
        var lo = 0
        var hi = knots.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Double(knots[mid].t) < t { lo = mid + 1 } else { hi = mid }
        }
        let b = knots[lo]
        let a = knots[lo - 1]
        let f = (t - Double(a.t)) / Double(b.t - a.t)
        return a.at + f * (b.at - a.at)
    }

    /// The smallest simulated time (µs) whose presentation time is at least `at` (ms), clamped to
    /// the first and last knot.
    public func simTime(atPresentation at: Double) -> Double {
        let first = knots[0]
        let last = knots[knots.count - 1]
        if at <= first.at { return Double(first.t) }
        if at >= last.at { return Double(last.t) }
        // First knot with knot.at >= at; its predecessor has a smaller `at`, so the segment is not flat.
        var lo = 0
        var hi = knots.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if knots[mid].at < at { lo = mid + 1 } else { hi = mid }
        }
        let b = knots[lo]
        let a = knots[lo - 1]
        let f = (at - a.at) / (b.at - a.at)
        return Double(a.t) + f * Double(b.t - a.t)
    }

    /// The right side's presentation time for a left presentation time: `right.at(simTime: left.T(at))`.
    public func counterpart(ofLeftTime leftAt: Double, left: SyncMap) -> Double {
        at(simTime: left.simTime(atPresentation: leftAt))
    }
}
