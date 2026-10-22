import Foundation

public enum PauseReason: String, Sendable, Equatable {
    case user, marker, end
}

/// What a click on the stage hit (the player's `HitResult`): the topmost drawn circle or rect
/// that carries a node or a message, with its resolved `node` name and trace message id.
public struct StageHit: Sendable, Equatable {
    public let id: String
    public let kind: String
    public let node: String?
    public let msg: Int?
    public init(id: String, kind: String, node: String?, msg: Int?) {
        self.id = id; self.kind = kind; self.node = node; self.msg = msg
    }

    static func decode(_ any: Any?) -> StageHit? {
        guard let d = any as? [String: Any], let id = d["id"] as? String, let kind = d["kind"] as? String else { return nil }
        return StageHit(id: id, kind: kind, node: d["node"] as? String, msg: PlayerEvent.number(d["msg"]).map { Int($0) })
    }
}

/// A rectangle in CSS pixels of the stage canvas.
public struct StageRect: Sendable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

    static func decode(_ any: Any?) -> StageRect? {
        guard let d = any as? [String: Any], let x = PlayerEvent.number(d["x"]), let y = PlayerEvent.number(d["y"]),
              let w = PlayerEvent.number(d["w"]), let h = PlayerEvent.number(d["h"]) else { return nil }
        return StageRect(x: x, y: y, w: w, h: h)
    }

    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px <= x + w && py >= y && py <= y + h }
    public func intersects(_ o: StageRect) -> Bool { x <= o.x + o.w && o.x <= x + w && y <= o.y + o.h && o.y <= y + h }
}

/// The box of a node on the stage (the player's `NodeBox`): CSS pixels of the canvas, no slop.
public struct StageNodeBox: Sendable, Equatable {
    public let node: String
    public let rect: StageRect
    public init(node: String, rect: StageRect) { self.node = node; self.rect = rect }

    static func decode(_ any: Any?) -> StageNodeBox? {
        guard let d = any as? [String: Any], let node = d["node"] as? String, let r = StageRect.decode(d) else { return nil }
        return StageNodeBox(node: node, rect: r)
    }
}

/// One message from the page: the player bridge (time, marker, fact, play, pause, scene)
/// or the host script (ready, error).
public enum PlayerEvent: Sendable, Equatable {
    case ready
    case time(at: Double)
    /// `choices` are the Predict choices of a `pause` marker (empty when it has none).
    case marker(kind: String, at: Double, text: String, choices: [String] = [])
    case fact(seq: Int, at: Double)
    case play
    case pause(reason: PauseReason)
    case scene
    /// A click on the stage at (x, y) CSS px of the canvas; `hit` is nil when nothing was hit.
    case click(x: Double, y: Double, hit: StageHit?)
    /// A drag rectangle on the stage and the names of the nodes whose boxes it touches.
    case box(rect: StageRect, nodes: [String])
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
            let choices = (m["choices"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .marker(kind: kind, at: at, text: (m["text"] as? String) ?? "", choices: kind == "pause" ? choices : [])
        case "fact":
            guard let seq = number(dict["seq"]), let at = number(dict["at"]) else { return nil }
            return .fact(seq: Int(seq), at: at)
        case "play": return .play
        case "pause":
            let reason = (dict["reason"] as? String).flatMap(PauseReason.init(rawValue:)) ?? .user
            return .pause(reason: reason)
        case "scene": return .scene
        case "click":
            guard let x = number(dict["x"]), let y = number(dict["y"]) else { return nil }
            return .click(x: x, y: y, hit: StageHit.decode(dict["hit"]))
        case "box":
            guard let rect = StageRect.decode(dict["rect"]) else { return nil }
            return .box(rect: rect, nodes: (dict["nodes"] as? [Any])?.compactMap { $0 as? String } ?? [])
        case "error": return .error((dict["message"] as? String) ?? "unknown error")
        default: return nil
        }
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        return any as? Double
    }
}
