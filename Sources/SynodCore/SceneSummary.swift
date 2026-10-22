import Foundation

/// The parts of `scene.json` the app needs besides the drawing itself (format `synod-scene/1`).
/// The scene text goes to the player unchanged; this is only its summary.
public struct SceneSummary: Sendable, Equatable, Decodable {
    public struct Canvas: Sendable, Equatable, Decodable {
        public let w: Double
        public let h: Double
    }

    /// A timeline marker. Readers ignore kinds they do not know.
    public struct Marker: Sendable, Equatable, Decodable {
        public enum Kind: String, Sendable {
            case pause, caption, broken, failed
        }

        /// Presentation time in ms.
        public let at: Double
        public let kind: String
        public let text: String
        /// The choices of a `pause` marker written with `lesson.Ask … choosing` (decision 82);
        /// empty for an open question and for every other kind.
        public let choices: [String]

        /// The marker kind when known.
        public var known: Kind? { Kind(rawValue: kind) }

        public init(at: Double, kind: String, text: String, choices: [String] = []) {
            self.at = at
            self.kind = kind
            self.text = text
            self.choices = choices
        }

        enum CodingKeys: String, CodingKey { case at, kind, text, choices }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try c.decode(Double.self, forKey: .at)
            kind = try c.decode(String.self, forKey: .kind)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            // Only pause markers carry choices; a malformed list counts as no choices.
            let list = (try? c.decodeIfPresent([String].self, forKey: .choices)) ?? nil
            choices = kind == "pause" ? (list ?? []) : []
        }
    }

    /// Maps a trace `seq` to its presentation time in ms.
    public struct TraceEntry: Sendable, Equatable, Decodable {
        public let seq: Int
        public let at: Double
        public init(seq: Int, at: Double) {
            self.seq = seq
            self.at = at
        }
    }

    public let format: String
    /// Scene length in ms.
    public let duration: Double
    public let canvas: Canvas
    public let markers: [Marker]
    public let trace: [TraceEntry]

    enum CodingKeys: String, CodingKey { case format, duration, canvas, markers, trace }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        try FormatError.require(format, name: "synod-scene")
        duration = try c.decode(Double.self, forKey: .duration)
        canvas = try c.decode(Canvas.self, forKey: .canvas)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        trace = try c.decodeIfPresent([TraceEntry].self, forKey: .trace) ?? []
    }

    /// Reads the summary of a scene document; rejects a major version other than 1.
    public static func parse(_ text: String) throws -> SceneSummary {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> SceneSummary {
        do {
            return try JSONDecoder().decode(SceneSummary.self, from: data)
        } catch let e as DecodingError {
            throw FormatError.malformed("scene.json: \(e.localizedDescription)")
        }
    }
}
