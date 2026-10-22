import Foundation

public enum PauseReason: String, Sendable, Equatable {
    case user, marker, end
}

/// One message from the page: the player bridge (time, marker, fact, play, pause, scene)
/// or the host script (ready, error).
public enum PlayerEvent: Sendable, Equatable {
    case ready
    case time(at: Double)
    case marker(kind: String, at: Double, text: String)
    case fact(seq: Int, at: Double)
    case play
    case pause(reason: PauseReason)
    case scene
    case error(String)

    /// Decodes a `postMessage` body. Returns nil for unknown events and malformed payloads.
    public static func decode(_ body: Any) -> PlayerEvent? {
        guard let dict = body as? [String: Any], let name = dict["event"] as? String else { return nil }
        switch name {
        case "ready": return .ready
        case "time":
            guard let at = number(dict["at"]) else { return nil }
            return .time(at: at)
        case "marker":
            guard let m = dict["marker"] as? [String: Any], let at = number(m["at"]),
                  let kind = m["kind"] as? String else { return nil }
            return .marker(kind: kind, at: at, text: (m["text"] as? String) ?? "")
        case "fact":
            guard let seq = number(dict["seq"]), let at = number(dict["at"]) else { return nil }
            return .fact(seq: Int(seq), at: at)
        case "play": return .play
        case "pause":
            let reason = (dict["reason"] as? String).flatMap(PauseReason.init(rawValue:)) ?? .user
            return .pause(reason: reason)
        case "scene": return .scene
        case "error": return .error((dict["message"] as? String) ?? "unknown error")
        default: return nil
        }
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        return any as? Double
    }
}
