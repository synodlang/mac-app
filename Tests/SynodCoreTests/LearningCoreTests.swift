import Foundation
import Testing

@testable import SynodCore

// MARK: Duration literals (spec/10)

@Test func durationLiteralsAreCanonical() {
    #expect(durationLiteral(microseconds: 0) == "0s")
    #expect(durationLiteral(microseconds: 6_001_000) == "6001ms")
    #expect(durationLiteral(microseconds: 7_000_000) == "7s")
    #expect(durationLiteral(microseconds: 20_431) == "20.431ms")
    #expect(durationLiteral(microseconds: 1_500_000) == "1500ms")
    #expect(durationLiteral(microseconds: 500) == "0.5ms")
    #expect(durationLiteral(microseconds: 1) == "0.001ms")
    #expect(durationLiteral(microseconds: 1_000) == "1ms")
    #expect(durationLiteral(microseconds: 1_000_001) == "1000.001ms")
    #expect(durationLiteral(microseconds: 60_000_000) == "60s")
}

// MARK: Sync map

private func cassandra() throws -> TraceIndex { try Fixtures.index("cassandra") }

@Test func syncMapKnotsFollowTheSpec() throws {
    let index = try cassandra()
    let map = SyncMap(index: index, duration: try Fixtures.scene("cassandra").duration)
    #expect(map.knots.first == SyncMap.Knot(t: 0, at: map.knots[0].at))
    #expect(map.endTime == 30_000_000, "the time of sim.Ended")
    #expect(map.duration == 134_786)
    // Strictly increasing in t, non-decreasing in at.
    for (a, b) in zip(map.knots, map.knots.dropFirst()) {
        #expect(a.t < b.t)
        #expect(a.at <= b.at)
    }
    // The knot at a fact time holds the largest slot of the facts at that time.
    let events = index.events.filter { $0.t == 6_000_000 }
    let slots = events.compactMap { index.timeOfSeq($0.seq) }
    #expect(!slots.isEmpty)
    #expect(map.knots.first { $0.t == 6_000_000 }?.at == slots.max())
    #expect(map.knots.count == Set(index.events.map(\.t)).count, "one knot per distinct fact time (the end is a fact time here)")
}

@Test func syncMapRoundTripsOnRealRuns() throws {
    for name in Fixtures.examples {
        let index = try Fixtures.index(name)
        let map = SyncMap(index: index, duration: try Fixtures.scene(name).duration)
        var rng = SplitMix(seed: 7)
        for _ in 0..<400 {
            // From the first knot's slot on, where the map is a bijection onto the scene.
            let lo = map.knots[0].at
            let at = lo + Double(rng.next() % 1_000_000) / 1_000_000 * (map.duration - lo)
            let t = map.simTime(atPresentation: at)
            let back = map.at(simTime: t)
            #expect(abs(back - at) < 1e-6, "\(name) at \(at)")
        }
        // Monotone both ways.
        let ts = (0...200).map { Double($0) / 200 * Double(map.endTime) }
        let ats = ts.map { map.at(simTime: $0) }
        #expect(zip(ats, ats.dropFirst()).allSatisfy { $0 <= $1 })
        let ats2 = (0...200).map { Double($0) / 200 * map.duration }
        let ts2 = ats2.map { map.simTime(atPresentation: $0) }
        #expect(zip(ts2, ts2.dropFirst()).allSatisfy { $0 <= $1 })
        // Clamping.
        #expect(map.at(simTime: -5) == map.knots[0].at)
        #expect(map.at(simTime: Double(map.endTime) * 2) == map.duration)
        #expect(map.simTime(atPresentation: -1) == 0)
        #expect(map.simTime(atPresentation: map.duration * 2) == Double(map.endTime))
    }
}

@Test func syncMapOnASmallRunIsExact() throws {
    // Facts at 0, 0, 1000, 1000, 3000 µs in slots 0, 100, 200, 300, 900 ms; the scene lasts 1000 ms.
    let events = [
        #"{"seq":1,"t":0,"ev":"sim.Started"}"#,
        #"{"seq":2,"t":0,"ev":"sim.Added","node":"n1","runs":[],"state":{}}"#,
        #"{"seq":3,"t":1000,"ev":"sim.Fired","node":"n1"}"#,
        #"{"seq":4,"t":1000,"ev":"sim.Fired","node":"n1"}"#,
        #"{"seq":5,"t":3000,"ev":"sim.Fired","node":"n1"}"#,
    ]
    let index = try syntheticIndex(events, slots: [0, 100, 200, 300, 900], duration: 1000)
    let map = SyncMap(index: index, duration: 1000)
    #expect(map.knots == [.init(t: 0, at: 100), .init(t: 1000, at: 300), .init(t: 3000, at: 1000)])
    #expect(map.at(simTime: 0) == 100)
    #expect(map.at(simTime: 500) == 200)
    #expect(map.at(simTime: 2000) == 650)
    #expect(map.simTime(atPresentation: 200) == 500)
    #expect(map.simTime(atPresentation: 50) == 0, "the smallest T whose slot is at least 50")
    #expect(map.simTime(atPresentation: 650) == 2000)

    // The right side of a comparison follows the left through simulated time.
    let right = SyncMap(knots: [.init(t: 0, at: 0), .init(t: 3000, at: 3000)])
    #expect(right.counterpart(ofLeftTime: 650, left: map) == 2000)
    #expect(right.counterpart(ofLeftTime: 5000, left: map) == 3000)
    // A map with a stray unordered or duplicate knot is repaired.
    let odd = SyncMap(knots: [.init(t: 10, at: 5), .init(t: 0, at: 9), .init(t: 10, at: 7)])
    #expect(odd.knots == [.init(t: 0, at: 9), .init(t: 10, at: 9)])
    #expect(SyncMap(knots: []).knots == [.init(t: 0, at: 0)])
}

@Test func syncMapEndsAtTheLastFactWithoutSimEnded() throws {
    let index = try syntheticIndex([
        #"{"seq":1,"t":0,"ev":"sim.Started"}"#,
        #"{"seq":2,"t":2000,"ev":"sim.Fired","node":"n1"}"#,
    ], slots: [0, 50], duration: 400)
    let map = SyncMap(index: index, duration: 400)
    #expect(map.endTime == 2000)
    #expect(map.at(simTime: 2000) == 400)
}

// MARK: Break it plans

@Test func planCrashOnTheCassandraRun() throws {
    let planner = BreakItPlanner(index: try cassandra())
    #expect(planner.nodes(at: 6_001_000) == ["n1", "n2", "n3", "n4", "n5", "n6"])
    #expect(planner.defaultTime(factSeq: 313) == 6_001_000)
    #expect(planner.defaultTime(factSeq: nil) == 0)
    #expect(planner.defaultTime(factSeq: 312) <= 6_000_000, "the fact before the crash is earlier")
    #expect(planner.offer(forNode: "n5", factSeq: 312) == .crash)
    #expect(planner.offer(forNode: "n5", factSeq: 313) == .restart)
    #expect(planner.offer(forNode: "n5", factSeq: 809) == .restart)
    #expect(planner.offer(forNode: "n5", factSeq: 810) == .crash)
    #expect(planner.offer(forNode: "n5", factSeq: nil) == .none)
    #expect(planner.offer(forNode: "n9", factSeq: 312) == .none)

    let plan = try planner.plan(.crash(node: "n5"), factSeq: 313)
    #expect(plan.time == 6_001_000)
    #expect(plan.timeLiteral == "6001ms")
    #expect(plan.statement == "sim.Crash (item 4 of sim.Nodes) # n5")
    #expect(plan.blockLines == ["  after 6001ms", "    sim.Crash (item 4 of sim.Nodes) # n5"])
    #expect(plan.imports == ["std/sim"])

    let restart = try planner.plan(.restart(node: "n5"), factSeq: 810)
    #expect(restart.time == 18_001_000)
    #expect(restart.statement == "sim.Restart (item 4 of sim.Nodes) # n5")

    let moved = plan.retimed(to: 7_000_000)
    #expect(moved.blockLines[0] == "  after 7s")
    #expect(moved.expectation == .crashed(node: "n5", at: 7_000_000))

    #expect(throws: BreakItError.unknownNode("n9")) { try planner.plan(.crash(node: "n9"), at: 1000) }
}

@Test func planPartitionAndHeal() throws {
    let planner = BreakItPlanner(index: try cassandra())
    let plan = try planner.plan(.partition(selected: ["n2", "n1"]), factSeq: 313)
    #expect(plan.statement == "net.Partition {(item 0 of sim.Nodes), (item 1 of sim.Nodes)} from {(item 2 of sim.Nodes), (item 3 of sim.Nodes), (item 4 of sim.Nodes), (item 5 of sim.Nodes)} # n1, n2 from n3, n4, n5, n6")
    #expect(plan.imports == ["std/net", "std/sim"])
    #expect(plan.expectation == .partitioned(at: 6_001_000, a: ["n1", "n2"], b: ["n3", "n4", "n5", "n6"]))
    #expect(throws: BreakItError.needsBothSides) { try planner.plan(.partition(selected: []), at: 0) }
    #expect(throws: BreakItError.needsBothSides) { try planner.plan(.partition(selected: ["n1", "n2", "n3", "n4", "n5", "n6"]), at: 1_000_000) }
    #expect(throws: BreakItError.unknownNode("n7")) { try planner.plan(.partition(selected: ["n7"]), at: 1_000_000) }
    // Nodes added later are not on any side yet.
    #expect(planner.nodes(at: 0).isEmpty)

    let heal = try planner.plan(.heal, at: 2_000_000)
    #expect(heal.blockLines == ["  after 2s", "    net.Heal"])
    #expect(heal.imports == ["std/net"])
}

private let faultEvents = [
    #"{"seq":1,"t":0,"ev":"sim.Started"}"#,
    #"{"seq":2,"t":0,"ev":"sim.Added","node":"n1","runs":[],"state":{}}"#,
    #"{"seq":3,"t":0,"ev":"sim.Added","node":"n2","runs":[],"state":{}}"#,
    #"{"seq":4,"t":0,"ev":"sim.Added","node":"n3","runs":[],"state":{}}"#,
    #"{"seq":5,"t":2000,"ev":"net.Sent","node":"n1","msg":{"id":1,"type":"p.Accept","fields":{}},"from":"n1","to":"n2"}"#,
    #"{"seq":6,"t":2000,"ev":"net.Sent","node":"n1","msg":{"id":2,"type":"p.Accept","fields":{}},"from":"n1","to":"n2"}"#,
    #"{"seq":7,"t":3000,"ev":"net.Sent","node":"n1","msg":{"id":3,"type":"p.Accept","fields":{}},"from":"n1","to":"n2"}"#,
    #"{"seq":8,"t":2000,"ev":"net.Sent","node":"n2","msg":{"id":4,"type":"p.Ack","fields":{}},"from":"n2","to":"n1"}"#,
    #"{"seq":9,"t":20431,"ev":"net.Sent","node":"n3","msg":{"id":5,"type":"p.Ack","fields":{}},"from":"n3","to":"n1"}"#,
    #"{"seq":10,"t":5000000,"ev":"sim.Removed","node":"n2"}"#,
    #"{"seq":11,"t":6000000,"ev":"sim.Added","node":"n4","runs":[],"state":{}}"#,
    #"{"seq":12,"t":7000000,"ev":"net.Sent","node":"n4","msg":{"id":6,"type":"p.Accept","fields":{}},"from":"n4","to":"n3"}"#,
    #"{"seq":13,"t":7000000,"ev":"net.Partitioned","a":["n1"],"b":["n3","n4"]}"#,
    #"{"seq":14,"t":8000000,"ev":"net.Healed"}"#,
]

@Test func planDropMessageAndTheTwinRule() throws {
    let planner = BreakItPlanner(index: try syntheticIndex(faultEvents))
    #expect(planner.offer(forMessage: 1) == .available, "the first of two sent at that instant")
    #expect(planner.offer(forMessage: 2) == .disabled("Cannot single out this message"))
    #expect(planner.offer(forMessage: 3) == .available, "same link and type, another instant")
    #expect(planner.offer(forMessage: 4) == .available, "another type on another link")
    #expect(planner.offer(forMessage: 99) == .unknown)
    #expect(throws: BreakItError.cannotSingleOut) { try planner.plan(.dropMessage(id: 2)) }
    #expect(throws: BreakItError.unknownMessage(99)) { try planner.plan(.dropMessage(id: 99)) }

    let first = try planner.plan(.dropMessage(id: 1))
    #expect(first.time == 2000)
    #expect(first.blockLines == ["  after 2ms", "    net.DropNext \"Accept\" from (item 0 of sim.Nodes) to (item 1 of sim.Nodes) # n1 to n2"])
    #expect(first.imports == ["std/net", "std/sim"])
    #expect(first.expectation == .dropped(type: "Accept", from: "n1", to: "n2", sentAt: 2000))
    #expect(first.retimed(to: 5) == first, "a drop keeps the message's send time")

    let fractional = try planner.plan(.dropMessage(id: 5))
    #expect(fractional.blockLines[0] == "  after 20.431ms")
    #expect(fractional.statement == "net.DropNext \"Ack\" from (item 2 of sim.Nodes) to (item 0 of sim.Nodes) # n3 to n1")
}

@Test func nodeIndexesSkipRemovedNodes() throws {
    let planner = BreakItPlanner(index: try syntheticIndex(faultEvents))
    #expect(planner.nodes(at: 5_000_000) == ["n1", "n2", "n3"], "n2 is removed at 5 s, not before it")
    #expect(planner.nodes(at: 5_000_001) == ["n1", "n3"])
    #expect(planner.nodes(at: 7_000_000) == ["n1", "n3", "n4"])
    #expect(planner.nodes(at: 6_000_000) == ["n1", "n3"], "added at T is not there yet")
    let crash = try planner.plan(.crash(node: "n4"), at: 9_000_000)
    #expect(crash.statement == "sim.Crash (item 2 of sim.Nodes) # n4")
    #expect(throws: BreakItError.unknownNode("n2")) { try planner.plan(.crash(node: "n2"), at: 9_000_000) }
    // Message 6's link is both nodes at 7 s: n4 is added at 6 s, so it is item 2.
    let drop = try planner.plan(.dropMessage(id: 6))
    #expect(drop.statement == "net.DropNext \"Accept\" from (item 2 of sim.Nodes) to (item 1 of sim.Nodes) # n4 to n3")
    #expect(planner.partitionActive(factSeq: 12) == false)
    #expect(planner.partitionActive(factSeq: 13) == true)
    #expect(planner.partitionActive(factSeq: 14) == false)
    #expect(planner.partitionActive(factSeq: nil) == false)
}

// MARK: The main file edit

private let cassandraMain = """
# package main
use github.com/synodlang/examples/cassandra
use github.com/synodlang/examples/gossip
use github.com/synodlang/examples/ring
use std/lesson
use std/sim

define main
  sim.Seed 3
  set nodes to (sim.Cluster of 6 running cassandra)
  after 6s
    sim.Crash victim
  sim.StopAt 30s

"""

@Test func mainEditorAppendsTheBlockWhenImportsArePresent() throws {
    let crash = try BreakItPlanner(index: try cassandra()).plan(.crash(node: "n5"), factSeq: 313)
    let out = try MainEditor.apply(crash, to: cassandraMain)
    #expect(out == cassandraMain.replacingOccurrences(of: "  sim.StopAt 30s\n", with: "  sim.StopAt 30s\n  after 6001ms\n    sim.Crash (item 4 of sim.Nodes) # n5\n"))
    // Exactly one edit and it is an insertion.
    let edits = try MainEditor.edits(for: crash, in: cassandraMain)
    #expect(edits.count == 1 && edits[0].range.length == 0)
}

@Test func mainEditorAddsMissingImportsInByteOrder() throws {
    let partition = try BreakItPlanner(index: try cassandra()).plan(.partition(selected: ["n1"]), at: 1_000_000)
    let out = try MainEditor.apply(partition, to: cassandraMain)
    let expected = """
    # package main
    use github.com/synodlang/examples/cassandra
    use github.com/synodlang/examples/gossip
    use github.com/synodlang/examples/ring
    use std/lesson
    use std/net
    use std/sim

    define main
      sim.Seed 3
      set nodes to (sim.Cluster of 6 running cassandra)
      after 6s
        sim.Crash victim
      sim.StopAt 30s
      after 1s
        net.Partition {(item 0 of sim.Nodes)} from {(item 1 of sim.Nodes), (item 2 of sim.Nodes), (item 3 of sim.Nodes), (item 4 of sim.Nodes), (item 5 of sim.Nodes)} # n1 from n2, n3, n4, n5, n6

    """
    #expect(out == expected)
    // Edits are in descending order and do not overlap.
    let edits = try MainEditor.edits(for: partition, in: cassandraMain)
    #expect(edits.count == 2)
    #expect(edits[0].range.location > edits[1].range.location)
}

@Test func mainEditorAddsBothImportsAfterTheLastUse() throws {
    let text = "# package main\nuse example.com/p\n\ndefine main\n  set a to 1\n\ndefine other\n  set b to 2\n"
    let plan = try BreakItPlanner(index: try cassandra()).plan(.dropMessage(id: 6))
    let out = try MainEditor.apply(plan, to: text)
    #expect(out == """
    # package main
    use example.com/p
    use std/net
    use std/sim

    define main
      set a to 1
      after 1s
        net.DropNext "digest" from (item 0 of sim.Nodes) to (item 1 of sim.Nodes) # n1 to n2

    define other
      set b to 2

    """)
}

@Test func mainEditorEdgeCases() throws {
    let plan = try BreakItPlanner(index: try cassandra()).plan(.crash(node: "n1"), at: 1_000_000)
    // No use lines: after the header. No trailing newline: none is added. Empty main body.
    #expect(try MainEditor.apply(plan, to: "# package main\ndefine main") == "# package main\nuse std/sim\ndefine main\n  after 1s\n    sim.Crash (item 0 of sim.Nodes) # n1")
    // Comments inside the block belong to it; a top-level comment after a blank line does not.
    let withComments = "# package main\nuse std/sim\n\ndefine main\n  set a to 1\n  # note\n\n# detached\n"
    #expect(try MainEditor.apply(plan, to: withComments) == "# package main\nuse std/sim\n\ndefine main\n  set a to 1\n  # note\n  after 1s\n    sim.Crash (item 0 of sim.Nodes) # n1\n\n# detached\n")
    #expect(throws: BreakItError.noMainBlock) { try MainEditor.apply(plan, to: "# package main\ndefine other\n  set a to 1\n") }
    // Positions are UTF-16: a non-ASCII comment before the block must not shift the insertion.
    let unicode = "# package main\nuse std/sim\n\ndefine main\n  # héllo 😀\n  set a to 1\n"
    let out = try MainEditor.apply(plan, to: unicode)
    #expect(out == "# package main\nuse std/sim\n\ndefine main\n  # héllo 😀\n  set a to 1\n  after 1s\n    sim.Crash (item 0 of sim.Nodes) # n1\n")
}

// MARK: Verification

@Test func verifierFindsTheFactsOfTheCassandraRun() throws {
    let index = try cassandra()
    #expect(BreakItVerifier.verify(.crashed(node: "n5", at: 6_000_000), in: index) == 313)
    #expect(BreakItVerifier.verify(.crashed(node: "n5", at: 6_001_000), in: index) == nil)
    #expect(BreakItVerifier.verify(.crashed(node: "n4", at: 6_000_000), in: index) == nil)
    #expect(BreakItVerifier.verify(.restarted(node: "n5", at: 18_000_000), in: index) == 810)
    #expect(BreakItVerifier.verify(.restarted(node: "n5", at: 6_000_000), in: index) == nil)
    #expect(BreakItVerifier.verify(.healed(at: 1_000_000), in: index) == nil)
    // A plan for a time the run did not use has no effect in this run.
    let plan = try BreakItPlanner(index: index).plan(.crash(node: "n5"), factSeq: 313)
    #expect(BreakItVerifier.verify(plan, in: index) == nil)
}

@Test func verifierChecksPartitionHealAndDrop() throws {
    let events = faultEvents + [
        #"{"seq":15,"t":2500,"ev":"net.Dropped","node":"n2","msg":{"id":1,"type":"p.Accept","fields":{}},"from":"n1","to":"n2","reason":"targeted"}"#,
        #"{"seq":16,"t":3500,"ev":"net.Dropped","node":"n2","msg":{"id":3,"type":"p.Accept","fields":{}},"from":"n1","to":"n2","reason":"loss"}"#,
    ]
    // seq must be increasing for the index: renumber by appending after seq 14.
    let index = try syntheticIndex(events)
    #expect(BreakItVerifier.verify(.partitioned(at: 7_000_000, a: ["n3", "n4"], b: ["n1"]), in: index) == 13, "either order of the sides")
    #expect(BreakItVerifier.verify(.partitioned(at: 7_000_000, a: ["n1"], b: ["n3"]), in: index) == nil)
    #expect(BreakItVerifier.verify(.partitioned(at: 7_000_001, a: ["n1"], b: ["n3", "n4"]), in: index) == nil)
    #expect(BreakItVerifier.verify(.healed(at: 8_000_000), in: index) == 14)
    #expect(BreakItVerifier.verify(.healed(at: 8_000_001), in: index) == nil)
    // The drop is found through the send time of the dropped message.
    #expect(BreakItVerifier.verify(.dropped(type: "Accept", from: "n1", to: "n2", sentAt: 2000), in: index) == 15)
    #expect(BreakItVerifier.verify(.dropped(type: "Accept", from: "n1", to: "n2", sentAt: 3000), in: index) == nil, "a loss is not Break it's drop")
    #expect(BreakItVerifier.verify(.dropped(type: "Ack", from: "n1", to: "n2", sentAt: 2000), in: index) == nil)
    #expect(BreakItVerifier.verify(.dropped(type: "Accept", from: "n1", to: "n2", sentAt: 2001), in: index) == nil)
}

@Test func newlyBrokenRulesAndTheirLocations() throws {
    func broken(_ rules: [String]) throws -> TraceIndex {
        var lines = [#"{"seq":1,"t":0,"ev":"sim.Started"}"#]
        for (i, r) in rules.enumerated() { lines.append(#"{"seq":\#(i + 2),"t":\#((i + 1) * 1_000_000),"ev":"sim.Broken","rule":"\#(r)"}"#) }
        return try syntheticIndex(lines)
    }
    let a = "p/p.synod:12: always (x)"
    let b = "p/q.synod:7: always (y)"
    let before = try broken([a])
    let after = try broken([a, b, b])
    let fresh = BreakItVerifier.newlyBroken(previous: before, current: after)
    #expect(fresh == [BrokenFact(rule: b, seq: 3, time: 2_000_000)], "compared by rule text, once each")
    #expect(fresh[0].location == RuleLocation(rule: b))
    #expect(RuleLocation(rule: b)?.file == "p/q.synod" && RuleLocation(rule: b)?.line == 7)
    #expect(BreakItVerifier.newlyBroken(previous: nil, current: after).map(\.rule) == [a, b])
    #expect(BreakItVerifier.newlyBroken(previous: after, current: before).isEmpty)
    #expect(RuleLocation(rule: "no location here") == nil)
    #expect(RuleLocation(rule: "x.synod:0: always") == nil)
    #expect(RuleLocation(rule: "x.synod:abc: always") == nil)
}

// MARK: Predict choices

@Test func sceneMarkersCarryChoices() throws {
    let scene = try Fixtures.scene("cassandra")
    let pause = try #require(scene.markers.first { $0.known == .pause })
    #expect(pause.choices == ["It fails until the replica returns", "It succeeds; a hint replays it when the replica returns", "It succeeds, but the replica never gets it"])
    #expect(scene.markers.first { $0.known == .caption }?.choices == [])
    // Every bundled demo offers choices since examples v0.2.1.
    #expect(try Fixtures.scene("tcp").markers.first { $0.known == .pause }?.choices.count == 4)

    let json = #"""
    {"format":"synod-scene/1","duration":10,"canvas":{"w":1,"h":1},"markers":[
     {"at":1,"kind":"pause","text":"q","choices":["a","b"]},
     {"at":2,"kind":"caption","text":"c","choices":["x","y"]},
     {"at":3,"kind":"pause","text":"q","choices":"oops"},
     {"at":4,"kind":"pause","text":"q"}],"trace":[]}
    """#
    let markers = try SceneSummary.parse(json).markers
    #expect(markers.map(\.choices) == [["a", "b"], [], [], []], "only pause markers have choices; a bad list is none")
}

@Test func answersWithChoicesRoundTripAndOldFilesStillDecode() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = CachePaths.under(dir)
    let root = dir.appendingPathComponent("mod")
    let store = AnswerStore(moduleRoot: root, program: "cassandra", paths: paths)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let choices = ["It fails until the replica returns", "It succeeds; a hint replays it when the replica returns"]
    let picked = AnswerStore.Entry(question: "What happens?", answer: choices[1], seed: 3, mode: "ordered", date: date, choice: 1, choices: choices)
    let open = AnswerStore.Entry(question: "Why?", answer: "term", seed: nil, mode: "ordered", date: date)
    try store.save(picked)
    try store.save(open)
    #expect(store.entry(for: "What happens?") == picked)
    #expect(store.entry(for: "What happens?")?.choice == 1)
    #expect(store.entry(for: "What happens?")?.choices == choices)
    #expect(store.entry(for: "Why?")?.choice == nil)
    let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(raw.contains("\"choice\" : 1"))
    // The open answer has no choice keys.
    let onlyOpen = AnswerStore(moduleRoot: root, program: "other", paths: paths)
    try onlyOpen.save(open)
    #expect(!(try String(contentsOf: onlyOpen.fileURL, encoding: .utf8)).contains("choice"))

    // A file written by M8 (no choice keys) decodes.
    let old = AnswerStore(moduleRoot: root, program: "old", paths: paths)
    try FileManager.default.createDirectory(at: old.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"[{"answer":"n3","date":"2023-11-14T22:13:20Z","mode":"ordered","question":"Who?","seed":3}]"#.write(to: old.fileURL, atomically: true, encoding: .utf8)
    let entry = try #require(old.entry(for: "Who?"))
    #expect(entry.answer == "n3" && entry.seed == 3 && entry.choice == nil && entry.choices == nil)
    // Saving next to an old entry keeps it.
    try old.save(picked)
    #expect(old.all().count == 2)
}

// MARK: Against the development compiler

/// The compiler built by `scripts/local-deps.sh`, when present (it has `--overlay` and lexical tokens).
private let localSynod: URL? = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let fm = FileManager.default
    let bin = url.appendingPathComponent(".deps/synod/synod")
    guard fm.isExecutableFile(atPath: bin.path), fm.fileExists(atPath: url.appendingPathComponent(".deps/.local").path),
        fm.fileExists(atPath: url.appendingPathComponent(".deps/examples/synod.mod").path)
    else { return nil }
    return bin
}()

private func examplesCopy() throws -> (dir: URL, workspace: Workspace) {
    let dir = try makeTempDir()
    let src = localSynod!.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples")
    let dst = dir.appendingPathComponent("examples")
    try FileManager.default.copyItem(at: src, to: dst)
    return (dir, try Workspace.open(dst))
}

@Test(.enabled(if: localSynod != nil, "needs scripts/local-deps.sh"))
func devCompilerChecksTokensAndOverlays() async throws {
    let (dir, ws) = try examplesCopy()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = SynodRunner(executable: localSynod!)
    let checker = OverlayChecker(workspace: ws, runner: runner, cache: CachePaths.under(dir))

    // Tokens of a clean program: every user file listed, every token fits its text.
    let clean = try await checker.check(target: "tcp")
    #expect(clean.ok)
    let demo = try #require(clean.tokens(for: "tcp/demo.synod"))
    #expect(!demo.tokens.isEmpty && !demo.looksLexicalOnly)
    #expect(clean.files.map(\.file).allSatisfy { !$0.hasPrefix("std/") })
    let text = try String(contentsOf: ws.url(forRelative: "tcp/demo.synod"), encoding: .utf8)
    let positions = TextPositions(text)
    let placed = PositionedToken.place(demo.tokens, in: positions)
    #expect(placed.count == demo.tokens.count)
    let ns = text as NSString
    #expect(demo.tokens.first?.role == .comment)
    #expect(ns.substring(with: placed[1].range) == "use", "the first word of line 2")

    // An unsaved buffer is checked in place of the file; the disk is not touched.
    let broken = text + "\nthis is ( not synod\n"
    let withError = try await checker.check(target: "tcp", buffers: ["tcp/demo.synod": broken])
    #expect(withError.hasErrors)
    #expect(withError.diagnostics.allSatisfy { $0.file == "tcp/demo.synod" })
    #expect(try String(contentsOf: ws.url(forRelative: "tcp/demo.synod"), encoding: .utf8) == text)
    // Parse errors keep complete lexical highlighting for the file and its siblings.
    let lexical = try #require(withError.tokens(for: "tcp/demo.synod"))
    #expect(lexical.tokens.count > demo.tokens.count)
    #expect(lexical.looksLexicalOnly)
    #expect(withError.tokens(for: "tcp/tcp.synod") != nil)

    // A key that is not a file is a tool error.
    await #expect(throws: PipelineError.self) { try await checker.check(target: "tcp", buffers: ["tcp/missing.synod": "x"]) }

    // Formatting keeps a canonical file as it is.
    let fmt = Formatter(workspace: ws, runner: runner)
    #expect(try await fmt.format(relativePath: "tcp/demo.synod") == .formatted(changed: false))
}

@Test(.enabled(if: localSynod != nil, "needs scripts/local-deps.sh"))
func breakItEditsCompileAndTakeEffectInTheDevCompiler() async throws {
    let (dir, ws) = try examplesCopy()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = SynodRunner(executable: localSynod!)
    let cache = CachePaths.under(dir)
    let pipeline = RunPipeline(workspace: ws, runner: runner, cache: cache)
    let program = try #require(ws.scan().programs.first { $0.relPath == "cassandra" })
    let mainURL = ws.url(forRelative: "cassandra/demo.synod")
    let original = try String(contentsOf: mainURL, encoding: .utf8)

    // The run the clicks refer to; its trace is what the fixture holds.
    guard case .ran(_, _, _, let base) = try await pipeline.run(program: program) else { Issue.record("base run failed"); return }
    let planner = BreakItPlanner(index: base)
    let sent = try #require(base.events.compactMap { e -> (TraceEvent, TraceEnvelope)? in
        if case .sent(let env) = e.payload, e.t > 1_000_000 { return (e, env) }
        return nil
    }.first { planner.offer(forMessage: $0.1.msg.id) == .available })

    let plans: [BreakItPlan] = [
        try planner.plan(.crash(node: "n3"), factSeq: 313),
        try planner.plan(.restart(node: "n5"), factSeq: 313),
        try planner.plan(.partition(selected: ["n1", "n2"]), factSeq: 313),
        try planner.plan(.heal, factSeq: 313),
        try planner.plan(.dropMessage(id: sent.1.msg.id)),
    ]
    for plan in plans {
        let edited = try MainEditor.apply(plan, to: original)
        try edited.write(to: mainURL, atomically: true, encoding: .utf8)
        defer { try? original.write(to: mainURL, atomically: true, encoding: .utf8) }

        // Unsaved first: the edit compiles, and formatting leaves it as it is.
        let fmt = try await Formatter(workspace: ws, runner: runner).format(relativePath: "cassandra/demo.synod")
        #expect(fmt == .formatted(changed: false), "\(plan.statement)")
        let result = try await pipeline.runDetailed(program: program)
        guard case .ran(_, _, _, let index) = result.outcome else { Issue.record("no run after: \(plan.statement)"); continue }
        // Crash, restart and heal of the cassandra run may legitimately have no effect (a node
        // already down, no partition): only the ones that must take effect are asserted.
        switch plan.action {
        case .crash, .partition, .dropMessage:
            #expect(BreakItVerifier.verify(plan, in: index) != nil, "\(plan.statement) took effect")
        case .restart, .heal:
            break
        }
    }
}

// MARK: Break it at the end of a run

@Test func defaultTimeAtTheEndOfTheRunStaysInsideIt() throws {
    let index = try syntheticIndex([
        #"{"seq":1,"t":0,"ev":"sim.Added","node":"n1","runs":[],"state":{}}"#,
        #"{"seq":2,"t":0,"ev":"sim.Added","node":"n2","runs":[],"state":{}}"#,
        #"{"seq":3,"t":7999500,"ev":"sim.Fired","node":"n1"}"#,
        #"{"seq":5,"t":8000000,"ev":"sim.Ended","reason":"stop"}"#,
    ])
    let planner = BreakItPlanner(index: index)
    #expect(planner.endTime == 8_000_000)
    // The fact after the last whole millisecond: clamp to the last whole ms before the end.
    #expect(planner.defaultTime(factSeq: 3) == 7_999_000)
    #expect(planner.defaultTime(factSeq: 5) == 7_999_000)
    // A fact seq without its own event (the player's last entry) uses the event before it.
    #expect(planner.defaultTime(factSeq: 4) == 7_999_000)
    #expect(planner.defaultTime(factSeq: 2) == 1_000)
    #expect(planner.offer(forNode: "n2", factSeq: 5) == .crash)
    let plan = try planner.plan(.crash(node: "n2"), factSeq: 5)
    #expect(plan.time == 7_999_000)
    #expect(plan.statement == "sim.Crash (item 1 of sim.Nodes) # n2")
}
