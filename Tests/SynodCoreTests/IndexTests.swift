import Foundation
import Testing

@testable import SynodCore

// MARK: factAt and time

@Test(arguments: Fixtures.examples)
func factAtMatchesBruteForce(example: String) throws {
    let index = try Fixtures.index(example)
    let entries = index.entries
    var rng = SplitMix(seed: 42)
    let maxAt = (entries.last?.at ?? 100) + 500
    var samples: [Double] = [-5, 0, maxAt, 1e9] + entries.map(\.at) + entries.map { $0.at - 0.5 }
    for _ in 0..<2000 { samples.append(Double.random(in: -10...maxAt, using: &rng)) }
    for t in samples {
        let expected = entries.last { $0.at <= t }
        #expect(index.factAt(t) == expected, "t=\(t)")
    }
}

@Test func timeOfSeqFollowsTheSceneMap() throws {
    let index = try Fixtures.index("raft")
    for e in index.entries.prefix(50) { #expect(index.timeOfSeq(e.seq) == e.at) }
    #expect(index.timeOfSeq(-1) == nil)
    #expect(index.timeOfSeq(99999) == nil)
    #expect(index.simTime(ofSeq: 1) == SimTime(microseconds: 0))
    #expect(index.event(seq: 2)?.ev == "sim.Added")
    #expect(index.event(seq: 0) == nil)
}

// MARK: state replay

@Test func nodesInFirstAddedOrder() throws {
    let index = try Fixtures.index("raft")
    #expect(index.nodes == ["n1", "n2", "n3", "n4", "n5"])
    let tcp = try Fixtures.index("tcp")
    #expect(tcp.nodes == ["n1", "n2"])
}

@Test(arguments: Fixtures.examples)
func checkpointedStateEqualsNaiveReplay(example: String) throws {
    let index = try Fixtures.index(example)
    var rng = SplitMix(seed: 7)
    let lastSeq = index.events.last!.seq
    var seqs = (0..<200).map { _ in Int.random(in: 0...lastSeq + 3, using: &rng) }
    // Around the checkpoint boundaries too.
    seqs += [255, 256, 257, 511, 512, 513, 1, lastSeq, lastSeq + 10].filter { $0 >= 0 }
    for seq in seqs {
        for node in index.nodes {
            #expect(index.state(of: node, atSeq: seq) == index.naiveState(of: node, atSeq: seq), "\(example) \(node) @\(seq)")
        }
    }
    #expect(index.state(of: "n99", atSeq: lastSeq) == nil)
}

@Test func stateBeforeAddedIsNilAndFieldsChange() throws {
    let index = try Fixtures.index("raft")
    #expect(index.state(of: "n1", atSeq: 1) == nil)
    let initial = try #require(index.state(of: "n1", atSeq: 2))
    #expect(initial.status == .up)
    #expect(initial.value(of: "raft.Role") == .text("follower"))
    #expect(initial.changedFields(atSeq: 2).contains("raft.Role"))
    // The first role change of any node.
    let change = try #require(index.events.first {
        if case .changed(let f, _, _) = $0.payload { return f == "raft.Role" } else { return false }
    })
    guard case .changed(_, let old, let new) = change.payload, let node = change.node else { return }
    let before = try #require(index.state(of: node, atSeq: change.seq - 1))
    let after = try #require(index.state(of: node, atSeq: change.seq))
    #expect(before.value(of: "raft.Role") == old)
    #expect(after.value(of: "raft.Role") == new)
    #expect(after.changedFields(atSeq: change.seq) == ["raft.Role"])
    #expect(before.changedFields(atSeq: change.seq).isEmpty)
}

@Test func crashAndRestartFlags() throws {
    let index = try Fixtures.index("raft")
    let crash = try #require(index.events.first { if case .crashed = $0.payload { return true } else { return false } })
    let restart = try #require(index.events.first {
        if case .restarted = $0.payload { return $0.node == crash.node && $0.seq > crash.seq } else { return false }
    })
    let node = try #require(crash.node)
    let before = try #require(index.state(of: node, atSeq: crash.seq - 1))
    let down = try #require(index.state(of: node, atSeq: crash.seq))
    #expect(before.status == .up)
    #expect(down.status == .crashed)
    #expect(down.fields == before.fields, "a crash keeps the last state")
    #expect(index.state(of: node, atSeq: restart.seq - 1)?.status == .crashed)
    let up = try #require(index.state(of: node, atSeq: restart.seq))
    #expect(up.status == .up)
    guard case .restarted(_, let state) = restart.payload else { return }
    #expect(up.fields == state, "a restart replaces the state")
    #expect(up.changedFields(atSeq: restart.seq).count == state.count)
}

@Test func removedFlag() {
    let header = TraceHeader(format: "synod-trace/1", synod: "0.2", seed: 1, program: "p", packages: [])
    func ev(_ seq: Int, _ name: String, _ p: TracePayload) -> TraceEvent {
        TraceEvent(seq: seq, t: Int64(seq), ev: name, node: "n1", payload: p, extra: [])
    }
    let index = TraceIndex(header: header, events: [
        ev(1, "sim.Added", .added(runs: ["p"], state: [StateField(name: "p.X", value: .number(1))])),
        ev(2, "sim.Changed", .changed(field: "p.X", old: .number(1), new: .number(2))),
        ev(3, "sim.Removed", .removed),
    ], entries: [])
    #expect(index.state(of: "n1", atSeq: 2)?.value(of: "p.X") == .number(2))
    #expect(index.state(of: "n1", atSeq: 3)?.status == .removed)
    #expect(index.state(of: "n1", atSeq: 3)?.value(of: "p.X") == .number(2))
}

// MARK: windows

@Test func windowBounds() throws {
    let index = try Fixtures.index("raft")
    let last = index.events.last!.seq
    let mid = index.window(around: 1000)
    #expect(mid.count == 81)
    #expect(mid.first?.seq == 960 && mid.last?.seq == 1040)
    let start = index.window(around: 1)
    #expect(start.first?.seq == 1 && start.count == 41)
    let end = index.window(around: last)
    #expect(end.last?.seq == last && end.count == 41)
    #expect(index.window(around: last + 500).last?.seq == last)
    #expect(index.window(around: 50, radius: 0).map(\.seq) == [50])
    #expect(index.window(around: 50, radius: 3).map(\.seq) == Array(47...53))
}

@Test func windowFilteredByNode() throws {
    let index = try Fixtures.index("raft")
    let w = index.window(around: 1000, radius: 10, node: "n2")
    #expect(w.count == 21)
    #expect(w.allSatisfy { e in
        if e.node == "n2" { return true }
        switch e.payload {
        case .sent(let m), .arrived(let m), .dropped(let m, _): return m.from == "n2" || m.to == "n2"
        default: return false
        }
    })
    #expect(w.map(\.seq) == w.map(\.seq).sorted())
    #expect(w.contains { $0.seq <= 1000 } && w.contains { $0.seq >= 1000 })
    #expect(index.window(around: 1, radius: 5, node: "n2").first?.seq == 3)
    #expect(index.window(around: 10, node: "nope").isEmpty)
}

@Test func oneLineUsesSummaryStyle() throws {
    let index = try Fixtures.index("tcp")
    #expect(index.oneLine(index.events[0]) == "sim.Started")
    #expect(index.oneLine(index.events[1]) == #"sim.Added n1 runs tcp: tcp.State "CLOSED""#)
    #expect(index.oneLine(index.events[3]) == #"sim.Changed tcp.State of n2 from "CLOSED" to "LISTEN""#)
}

// MARK: RunStatus

@Test func statusOK() {
    let s = RunStatusParser.parse("ok seed 3: stop at 8s, 5 nodes, 2197 events -> /tmp/t.jsonl\nscene 147.98s, 1928 shapes -> /tmp/s.json\n")
    #expect(s.result == .ok(seed: 3, reason: "stop", end: SimTime(microseconds: 8_000_000), nodes: 5, events: 2197, destination: "/tmp/t.jsonl"))
    #expect(s.scene == .ok(length: "147.98s", shapes: 1928, destination: "/tmp/s.json"))
    #expect(s.broken.isEmpty && s.unparsed.isEmpty && s.fault == nil)
}

@Test func statusSingularsAndStdout() {
    let s = RunStatusParser.parse("ok seed 18446744073709551615: empty at 0.5ms, 1 node, 1 event -> stdout\nscene 0.6s, 1 shape -> stdout\n")
    #expect(s.result == .ok(seed: .max, reason: "empty", end: SimTime(microseconds: 500), nodes: 1, events: 1, destination: "stdout"))
    #expect(s.scene == .ok(length: "0.6s", shapes: 1, destination: "stdout"))
}

@Test func statusBroken() {
    let one = RunStatusParser.parse("ok seed 1: stop at 8s, 3 nodes, 10 events -> t\nbroken at 90ms (1 time): paxos/paxos.synod:109: always (a at most 1)\nscene 1s, 2 shapes -> s\n")
    #expect(one.broken == [BrokenRule(time: SimTime(microseconds: 90_000), count: 1, rule: "paxos/paxos.synod:109: always (a at most 1)")])
    let many = RunStatusParser.parse("ok seed 1: stop at 8s, 3 nodes, 10 events -> t\nbroken at 1500ms (12 times): r.synod:1: always A\nbroken at 2s (2 times): r.synod:2: always B\n")
    #expect(many.broken.map(\.count) == [12, 2])
    #expect(many.broken[0].time.microseconds == 1_500_000)
    #expect(many.scene == nil)
}

@Test func statusFailed() throws {
    let s = RunStatusParser.parse("failed at 2s: raft/raft.synod:12:5: error[index-range]: index 4 is out of range\nscene 3s, 9 shapes -> s\n")
    #expect(s.fault == RunFault(time: SimTime(microseconds: 2_000_000), pos: SourcePos(file: "raft/raft.synod", line: 12, col: 5), code: "index-range", message: "index 4 is out of range"))
    #expect(s.scene != nil)
    let expect = try Fixtures.text("synced/errors/time-limit/expect.txt").split(separator: "\n").last.map(String.init) ?? ""
    let t = RunStatusParser.parse(expect)
    #expect(t.fault?.code == "time-limit")
    #expect(t.fault?.pos == nil)
    #expect(t.fault?.time.microseconds == 600_000_000)
    #expect(t.fault?.message == "the run reached 10 minutes of simulated time")
}

@Test func statusLookFailed() {
    let s = RunStatusParser.parse(try! Fixtures.text("own/look-failed.txt"))
    #expect(s.result != nil && s.fault == nil)
    let f = s.lookFault
    #expect(f?.code == "missing-key")
    #expect(f?.pos == SourcePos(file: "lk/lk.synod", line: 7, col: 3))
    #expect(f?.message == #"no shape is attached to "nope" under "card""#)
}

@Test func statusKeepsUnknownLines() {
    let s = RunStatusParser.parse("p/p.synod:3:1: error[missing-main]: no main file in p\n")
    #expect(!s.isRecognized)
    #expect(s.unparsed.count == 1)
}

@Test func sourcePosParsing() {
    #expect(SourcePos("a/b.synod:3:9") == SourcePos(file: "a/b.synod", line: 3, col: 9))
    #expect(SourcePos("a:b.synod:3:9")?.file == "a:b.synod")
    #expect(SourcePos("nope") == nil)
    #expect(SourcePos(file: "x", line: 1, col: 2).description == "x:1:2")
}

@Test func versionParsing() {
    let v = SynodVersion.parse("language 0.3\ncompiler v0.2.4 (f1262ee, 2026-10-22)\nformats synod-check/1 synod-trace/1 synod-scene/1\n")
    #expect(v.language == "0.3")
    #expect(v.compiler.hasPrefix("v0.2.4"))
    #expect(v.isCompatible)
    #expect(SynodVersion.parse("language 0.2\nformats synod-check/1 synod-trace/1 synod-scene/1").problem?.contains("0.3") == true)
    #expect(SynodVersion.parse("language 0.3\nformats synod-trace/1").problem?.contains("synod-scene/1") == true)
    #expect(SynodVersion.parse("").isCompatible == false)
}
