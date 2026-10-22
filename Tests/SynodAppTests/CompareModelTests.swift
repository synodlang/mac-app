import Foundation
import Testing
import SynodCore
@testable import SynodApp

private func state(_ json: String) throws -> NodeState {
    let header = #"{"format":"synod-trace/1","synod":"0.2","seed":1,"program":"p","packages":["p"]}"#
    let line = #"{"seq":1,"t":0,"ev":"sim.Added","node":"n1","runs":[],"state":\#(json)}"#
    let trace = try Trace.parse(Data([header, line].joined(separator: "\n").utf8))
    let scene = try SceneSummary.parse(#"{"format":"synod-scene/1","duration":1,"canvas":{"w":1,"h":1},"markers":[],"trace":[{"seq":1,"at":0}]}"#)
    return TraceIndex(trace: trace, scene: scene).state(of: "n1", atSeq: 1)!
}

@MainActor @Suite struct CompareLogicTests {
    @Test func nodesAreMatchedByName() {
        let p = CompareLogic.pairs(left: ["n1", "n2", "n3"], right: ["n2", "n1", "n4"])
        #expect(p.map { $0.name } == ["n1", "n2", "n3", "n4"])
        #expect(p.map { $0.isMatched } == [true, true, false, false])
        #expect(p[2].inLeft && !p[2].inRight)
        #expect(!p[3].inLeft && p[3].inRight)
    }

    @Test func differingFieldsAreMarked() throws {
        let l = try state(#"{"raft.Term":2,"raft.Role":"leader"}"#)
        let r = try state(#"{"raft.Term":2,"raft.Role":"follower","raft.Extra":1}"#)
        let rows = CompareLogic.rows(left: l, right: r)
        #expect(rows.map { $0.name } == ["raft.Term", "raft.Role", "raft.Extra"])
        #expect(rows.map { $0.differs } == [false, true, true])
        #expect(rows[2].left == nil)
        let onlyRight = CompareLogic.rows(left: nil, right: l)
        #expect(onlyRight.allSatisfy { $0.differs })
    }

    @Test func ticksLayOutOnTheSharedSimulatedAxis() {
        let left = SyncMap(knots: [.init(t: 0, at: 0), .init(t: 1_000_000, at: 100), .init(t: 2_000_000, at: 300)])
        let right = SyncMap(knots: [.init(t: 0, at: 0), .init(t: 2_000_000, at: 100)])
        let domain = CompareLogic.domain(left: left, right: right)
        #expect(domain == 2_000_000)
        let m = [SceneSummary.Marker(at: 100, kind: "pause", text: "Q"), SceneSummary.Marker(at: 300, kind: "caption", text: "c")]
        let lt = CompareLogic.ticks(markers: m, map: left, domain: domain, width: 200)
        #expect(lt.map { $0.x } == [100, 200])
        let rt = CompareLogic.ticks(markers: [SceneSummary.Marker(at: 50, kind: "pause", text: "Q")], map: right, domain: domain, width: 200)
        #expect(rt[0].x == 100)   // 50 ms of 100 is 1 s of the right run's 2 s: half the axis
        // Beyond the left end the tick clamps to the axis.
        #expect(CompareLogic.ticks(markers: [SceneSummary.Marker(at: 9999, kind: "x", text: "")], map: left, domain: domain, width: 200)[0].x == 200)
    }
}
