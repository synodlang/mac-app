import SynodWeb

/// The pure part of Predict: a `pause` marker followed by a pause with reason `marker` becomes
/// a question while Predict is on.
struct PredictLogic {
    private(set) var lastPauseMarker: String?

    /// Feeds one stage event; returns the question to ask when the player halted at a marker.
    mutating func handle(_ ev: PlayerEvent, predictEnabled: Bool) -> String? {
        switch ev {
        case .marker(let kind, _, let text) where kind == "pause":
            lastPauseMarker = text
        case .pause(let reason) where reason == .marker:
            let q = lastPauseMarker
            lastPauseMarker = nil
            return predictEnabled ? q : nil
        default: break
        }
        return nil
    }
}
