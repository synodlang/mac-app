import Foundation
import SynodCore

/// Pure layout and smoothing math for the timeline.
struct TimelineModel: Equatable {
    var duration: Double
    var markers: [SceneSummary.Marker]
    var factTimes: [Double]

    init(duration: Double, markers: [SceneSummary.Marker], factTimes: [Double]) {
        self.duration = duration
        self.markers = markers
        self.factTimes = factTimes
    }

    init(scene: SceneSummary) {
        self.init(duration: scene.duration, markers: scene.markers, factTimes: scene.trace.map(\.at))
    }

    static let empty = TimelineModel(duration: 0, markers: [], factTimes: [])

    struct Tick: Equatable {
        var x: Double
        var at: Double
        var kind: String
        var text: String
    }

    func fraction(at time: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    func time(atFraction f: Double) -> Double {
        min(max(f, 0), 1) * duration
    }

    /// The presentation time between 30 Hz `time` events: the last reported time plus the wall time
    /// since it, at the viewer's speed, clamped to the scene.
    static func smoothedTime(lastAt: Double, lastWall: Date, now: Date, rate: Double, playing: Bool, duration: Double) -> Double {
        guard playing else { return min(max(lastAt, 0), duration) }
        let elapsed = max(0, now.timeIntervalSince(lastWall)) * 1000 * rate
        return min(max(lastAt + elapsed, 0), duration)
    }

    static func severity(_ kind: String) -> Int {
        switch kind {
        case "failed": return 4
        case "broken": return 3
        case "pause": return 2
        case "caption": return 1
        default: return 0
        }
    }

    /// Marker ticks in points for a track `width` wide. Ticks closer than `minSpacing` points to the
    /// previous kept tick collapse into the more severe one.
    func ticks(width: Double, minSpacing: Double = 3) -> [Tick] {
        let all = markers.sorted { $0.at < $1.at }.map {
            Tick(x: fraction(at: $0.at) * width, at: $0.at, kind: $0.kind, text: $0.text)
        }
        var kept: [Tick] = []
        for t in all {
            if let last = kept.last, t.x - last.x < minSpacing {
                if Self.severity(t.kind) > Self.severity(last.kind) { kept[kept.count - 1] = t }
            } else {
                kept.append(t)
            }
        }
        return kept
    }

    /// Fact density per bin, normalized to 0...1.
    func density(bins: Int) -> [Double] {
        guard bins > 0 else { return [] }
        var counts = [Double](repeating: 0, count: bins)
        guard duration > 0 else { return counts }
        for t in factTimes {
            let i = min(bins - 1, max(0, Int(t / duration * Double(bins))))
            counts[i] += 1
        }
        let peak = counts.max() ?? 0
        return peak > 0 ? counts.map { $0 / peak } : counts
    }
}

/// Lets at most `perSecond` events through; used to cap seeks while scrubbing.
struct Throttle {
    var interval: TimeInterval
    private var last: TimeInterval = -.infinity

    init(perSecond: Double = 60) { interval = 1 / perSecond }

    mutating func allows(at now: TimeInterval) -> Bool {
        if now - last >= interval {
            last = now
            return true
        }
        return false
    }
}
