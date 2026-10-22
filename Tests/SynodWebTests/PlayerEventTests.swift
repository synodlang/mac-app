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
}
