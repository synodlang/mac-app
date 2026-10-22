import Testing
import SynodWeb
@testable import SynodApp

@MainActor @Suite struct PredictLogicTests {
    @Test func markerThenPauseAsksTheQuestion() {
        var p = PredictLogic()
        #expect(p.handle(.marker(kind: "pause", at: 7500, text: "Why?"), predictEnabled: true) == nil)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == "Why?")
    }

    @Test func nothingWhenPredictIsOff() {
        var p = PredictLogic()
        _ = p.handle(.marker(kind: "pause", at: 1, text: "Why?"), predictEnabled: false)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: false) == nil)
    }

    @Test func userAndEndPausesAndOtherMarkersAreIgnored() {
        var p = PredictLogic()
        _ = p.handle(.marker(kind: "caption", at: 1, text: "c"), predictEnabled: true)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == nil)
        _ = p.handle(.marker(kind: "pause", at: 1, text: "Q"), predictEnabled: true)
        #expect(p.handle(.pause(reason: .user), predictEnabled: true) == nil)
        #expect(p.handle(.pause(reason: .end), predictEnabled: true) == nil)
    }

    @Test func eachQuestionIsAskedOnce() {
        var p = PredictLogic()
        _ = p.handle(.marker(kind: "pause", at: 1, text: "Q"), predictEnabled: true)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == "Q")
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == nil)
    }
}
