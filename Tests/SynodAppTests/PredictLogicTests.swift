import Testing
import SynodWeb
@testable import SynodApp

@MainActor @Suite struct PredictLogicTests {
    @Test func markerThenPauseAsksTheQuestion() {
        var p = PredictLogic()
        #expect(p.handle(.marker(kind: "pause", at: 7500, text: "Why?"), predictEnabled: true) == nil)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == PredictLogic.Question(text: "Why?", choices: []))
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
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == PredictLogic.Question(text: "Q", choices: []))
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true) == nil)
    }

    @Test func choicesTravelWithTheQuestion() {
        var p = PredictLogic()
        _ = p.handle(.marker(kind: "pause", at: 1, text: "Q", choices: ["a", "b", "c"]), predictEnabled: true)
        let q = p.handle(.pause(reason: .marker), predictEnabled: true)
        #expect(q?.choices == ["a", "b", "c"])
        #expect(q?.text == "Q")
    }

    @Test func atMostSixChoices() {
        var p = PredictLogic()
        let many = (1...8).map { "c\($0)" }
        _ = p.handle(.marker(kind: "pause", at: 1, text: "Q", choices: many), predictEnabled: true)
        #expect(p.handle(.pause(reason: .marker), predictEnabled: true)?.choices.count == 6)
    }
}

@MainActor @Suite struct UnsavedChangesTests {
    @Test func messageNamesTheFiles() {
        #expect(UnsavedText.message(for: ["a.synod"]).title == "Do you want to save the changes to a.synod?")
        #expect(UnsavedText.message(for: ["a", "b"]).title.contains("2 files"))
    }
}
