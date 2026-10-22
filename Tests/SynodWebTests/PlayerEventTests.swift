import Foundation
import Testing
@testable import SynodWeb

@Suite struct PlayerEventTests {
    @Test func bridgePayloads() {
        #expect(PlayerEvent.decode(["event": "time", "at": 1234.5]) == .time(at: 1234.5))
        #expect(PlayerEvent.decode(["event": "time", "at": NSNumber(value: 40)]) == .time(at: 40))
        #expect(PlayerEvent.decode(["event": "marker", "marker": ["at": 5000, "kind": "pause", "text": "Who wins?"]])
            == .marker(kind: "pause", at: 5000, text: "Who wins?"))
        #expect(PlayerEvent.decode(["event": "fact", "seq": 12, "at": 800]) == .fact(seq: 12, at: 800))
        #expect(PlayerEvent.decode(["event": "play"]) == .play)
        #expect(PlayerEvent.decode(["event": "pause", "reason": "marker"]) == .pause(reason: .marker))
        #expect(PlayerEvent.decode(["event": "pause", "reason": "end"]) == .pause(reason: .end))
        #expect(PlayerEvent.decode(["event": "pause", "reason": "user"]) == .pause(reason: .user))
        #expect(PlayerEvent.decode(["event": "scene"]) == .scene)
    }

    @Test func hostPayloads() {
        #expect(PlayerEvent.decode(["event": "ready"]) == .ready)
        #expect(PlayerEvent.decode(["event": "error", "message": "boom"]) == .error("boom"))
        #expect(PlayerEvent.decode(["event": "error"]) == .error("unknown error"))
    }

    @Test func unknownAndMalformed() {
        #expect(PlayerEvent.decode(["event": "teleport"]) == nil)
        #expect(PlayerEvent.decode(["at": 1]) == nil)
        #expect(PlayerEvent.decode("time") == nil)
        #expect(PlayerEvent.decode(["event": "time"]) == nil)
        #expect(PlayerEvent.decode(["event": "fact", "seq": 1]) == nil)
        #expect(PlayerEvent.decode(["event": "marker", "marker": ["at": 1]]) == nil)
        // An unknown pause reason degrades to a user pause.
        #expect(PlayerEvent.decode(["event": "pause", "reason": "later"]) == .pause(reason: .user))
    }

    @Test func markerChoices() {
        let pause: [String: Any] = ["at": 4100, "kind": "pause", "text": "Who?", "choices": ["A", "B", "C"]]
        #expect(PlayerEvent.decode(["event": "marker", "marker": pause])
            == .marker(kind: "pause", at: 4100, text: "Who?", choices: ["A", "B", "C"]))
        // Without choices, or on another kind, there are none; non-strings are dropped.
        #expect(PlayerEvent.decode(["event": "marker", "marker": ["at": 1, "kind": "pause", "text": "Q"]])
            == .marker(kind: "pause", at: 1, text: "Q", choices: []))
        #expect(PlayerEvent.decode(["event": "marker", "marker": ["at": 1, "kind": "caption", "text": "c", "choices": ["x"]]])
            == .marker(kind: "caption", at: 1, text: "c", choices: []))
        #expect(PlayerEvent.decode(["event": "marker", "marker": ["at": 1, "kind": "pause", "text": "Q", "choices": ["x", 2, "y"]]])
            == .marker(kind: "pause", at: 1, text: "Q", choices: ["x", "y"]))
        // The three-argument form is the same event with no choices.
        #expect(PlayerEvent.marker(kind: "pause", at: 1, text: "Q") == .marker(kind: "pause", at: 1, text: "Q", choices: []))
    }

    @Test func clickEvents() {
        let hit: [String: Any] = ["id": "s1", "kind": "circle", "node": "n3", "msg": NSNull()]
        #expect(PlayerEvent.decode(["event": "click", "x": 120.5, "y": 40, "hit": hit])
            == .click(x: 120.5, y: 40, hit: StageHit(id: "s1", kind: "circle", node: "n3", msg: nil)))
        #expect(PlayerEvent.decode(["event": "click", "x": 1, "y": 2, "hit": ["id": "s9", "kind": "rect", "node": NSNull(), "msg": 5]])
            == .click(x: 1, y: 2, hit: StageHit(id: "s9", kind: "rect", node: nil, msg: 5)))
        #expect(PlayerEvent.decode(["event": "click", "x": 1, "y": 2, "hit": NSNull()]) == .click(x: 1, y: 2, hit: nil))
        #expect(PlayerEvent.decode(["event": "click", "x": 1, "y": 2]) == .click(x: 1, y: 2, hit: nil))
        #expect(PlayerEvent.decode(["event": "click", "x": 1]) == nil)
    }

    @Test func boxEvents() {
        let e = PlayerEvent.decode(["event": "box", "rect": ["x": 10, "y": 20, "w": 100, "h": 50], "nodes": ["n1", "n2"]])
        #expect(e == .box(rect: StageRect(x: 10, y: 20, w: 100, h: 50), nodes: ["n1", "n2"]))
        #expect(PlayerEvent.decode(["event": "box", "rect": ["x": 10, "y": 20, "w": 100, "h": 50]])
            == .box(rect: StageRect(x: 10, y: 20, w: 100, h: 50), nodes: []))
        #expect(PlayerEvent.decode(["event": "box", "nodes": ["n1"]]) == nil)
    }

    @Test func rectMath() {
        let r = StageRect(x: 10, y: 10, w: 20, h: 20)
        #expect(r.contains(x: 10, y: 30) && !r.contains(x: 31, y: 20))
        #expect(r.intersects(StageRect(x: 30, y: 30, w: 5, h: 5)))
        #expect(!r.intersects(StageRect(x: 31, y: 0, w: 5, h: 5)))
        let box = StageNodeBox.decode(["node": "n2", "x": 1, "y": 2, "w": 3, "h": 4])
        #expect(box == StageNodeBox(node: "n2", rect: StageRect(x: 1, y: 2, w: 3, h: 4)))
        #expect(StageNodeBox.decode(["x": 1, "y": 2, "w": 3, "h": 4]) == nil)
    }

    @Test func compareEvents() {
        #expect(CompareEvent.decode(["event": "time", "T": 5_000_000, "atL": 1200, "atR": 1300.5])
            == .time(CompareTimes(simMicros: 5_000_000, atLeft: 1200, atRight: 1300.5)))
        #expect(CompareEvent.decode(["event": "time", "at": 1]) == nil)
        #expect(CompareEvent.decode(["event": "click", "side": "right", "x": 1, "y": 2, "hit": NSNull()])
            == .click(side: .right, x: 1, y: 2, hit: nil))
        #expect(CompareEvent.decode(["event": "click", "side": "middle", "x": 1, "y": 2]) == nil)
        #expect(CompareEvent.decode(["event": "scene", "durationL": 100, "durationR": 200]) == .scene(durationLeft: 100, durationRight: 200))
        #expect(CompareEvent.decode(["event": "ready"]) == .ready)
        #expect(CompareEvent.decode(["event": "pause", "reason": "end"]) == .pause(reason: .end))
        #expect(CompareEvent.decode(["event": "marker", "marker": ["at": 1, "kind": "pause", "text": "Q", "choices": ["a", "b"]]])
            == .marker(kind: "pause", at: 1, text: "Q", choices: ["a", "b"]))
        #expect(CompareEvent.decode(["event": "error", "message": "x"]) == .error("x"))
        #expect(CompareEvent.decode(["event": "fact", "seq": 1, "at": 1]) == nil)
    }
}
