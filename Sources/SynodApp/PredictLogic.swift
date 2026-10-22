import SynodWeb

/// The pure part of Predict: a `pause` marker followed by a pause with reason `marker` becomes
/// a question while Predict is on. A marker written with `lesson.Ask … choosing` carries 2 to 6
/// choices (decision 82); without them the viewer types an answer.
struct PredictLogic {
    struct Question: Equatable {
        var text: String
        var choices: [String]
    }

    private(set) var lastPause: Question?

    /// The most choices the panel offers (keys 1 to 6).
    static let maxChoices = 6

    /// Feeds one stage event; returns the question to ask when the player halted at a marker.
    mutating func handle(_ ev: PlayerEvent, predictEnabled: Bool) -> Question? {
        switch ev {
        case .marker(let kind, _, let text, let choices) where kind == "pause":
            lastPause = Question(text: text, choices: Array(choices.prefix(Self.maxChoices)))
        case .pause(let reason) where reason == .marker:
            let q = lastPause
            lastPause = nil
            return predictEnabled ? q : nil
        default: break
        }
        return nil
    }
}
