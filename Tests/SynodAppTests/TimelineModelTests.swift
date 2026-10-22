import Foundation
import Testing
import SynodCore
@testable import SynodApp

@MainActor @Suite struct TimelineModelTests {
    let model = TimelineModel(
        duration: 10_000,
        markers: [
            .init(at: 1000, kind: "caption", text: "a"),
            .init(at: 1010, kind: "pause", text: "q?"),
            .init(at: 5000, kind: "broken", text: "b"),
            .init(at: 9000, kind: "failed", text: "f"),
        ],
        factTimes: [0, 10, 20, 5000, 5001, 9999])

    @Test func smoothingAdvancesWithWallTimeAtTheRate() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let now = t0.addingTimeInterval(0.5)
        #expect(TimelineModel.smoothedTime(lastAt: 2000, lastWall: t0, now: now, rate: 1, playing: true, duration: 10_000) == 2500)
        #expect(TimelineModel.smoothedTime(lastAt: 2000, lastWall: t0, now: now, rate: 4, playing: true, duration: 10_000) == 4000)
        #expect(TimelineModel.smoothedTime(lastAt: 2000, lastWall: t0, now: now, rate: 1, playing: false, duration: 10_000) == 2000)
        #expect(TimelineModel.smoothedTime(lastAt: 9900, lastWall: t0, now: now, rate: 1, playing: true, duration: 10_000) == 10_000)
        #expect(TimelineModel.smoothedTime(lastAt: 2000, lastWall: t0.addingTimeInterval(5), now: t0, rate: 1, playing: true, duration: 10_000) == 2000)
    }

    @Test func fractionsClampAndInvert() {
        #expect(model.fraction(at: 2500) == 0.25)
        #expect(model.fraction(at: -5) == 0)
        #expect(model.fraction(at: 99_999) == 1)
        #expect(model.time(atFraction: 0.5) == 5000)
        #expect(model.time(atFraction: 2) == 10_000)
        #expect(TimelineModel.empty.fraction(at: 5) == 0)
    }

    @Test func ticksLandOnTheTrackAndCollapseBySeverity() {
        let ticks = model.ticks(width: 1000, minSpacing: 3)
        // caption at 100 pt and pause at 101 pt collapse into the pause.
        #expect(ticks.map(\.kind) == ["pause", "broken", "failed"])
        #expect(ticks.map(\.x) == [101, 500, 900])
        let wide = model.ticks(width: 100_000, minSpacing: 3)
        #expect(wide.count == 4)
        #expect(wide.first?.x == 10_000)
    }

    @Test func densityIsNormalized() {
        let d = model.density(bins: 10)
        #expect(d.count == 10)
        #expect(d[0] == 1)
        #expect(d[5] == 2.0 / 3.0)
        #expect(d[9] == 1.0 / 3.0)
        #expect(d.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(TimelineModel.empty.density(bins: 4) == [0, 0, 0, 0])
    }

    @Test func throttleLimitsToSixtyPerSecond() {
        var t = Throttle(perSecond: 60)
        var passed = 0
        for i in 0..<1000 where t.allows(at: Double(i) / 1000) { passed += 1 }
        #expect(passed >= 59 && passed <= 61)
    }
}

@MainActor @Suite struct ProblemRowTests {
    @Test func faultsAndBrokenRulesBecomeRows() {
        let status = RunStatusParser.parse("""
        failed at 3s: a/b.synod:4:5: error[type-mismatch]: wrong type
        broken at 90ms (2 times): p/p.synod:109: always x
        """)
        let rows = ProblemRow.rows(report: nil, status: status, raw: nil, error: nil)
        #expect(rows.count == 2)
        #expect(rows[0].location == "a/b.synod:4:5")
        #expect(rows[1].severity == .warning)
    }
}
