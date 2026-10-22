import Foundation

/// Saved Predict answers of one program, in
/// `Application Support/Synod/answers/<hash of module root>/<program-path-with-dashes>.json`.
/// Entries are keyed by question text; a newer answer replaces an older one.
public struct AnswerStore: Sendable {
    public struct Entry: Sendable, Codable, Equatable {
        public var question: String
        public var answer: String
        public var seed: UInt64?
        public var mode: String
        public var date: Date
        public init(question: String, answer: String, seed: UInt64?, mode: String, date: Date = Date()) {
            self.question = question
            self.answer = answer
            self.seed = seed
            self.mode = mode
            self.date = date
        }
    }

    public let fileURL: URL

    public init(moduleRoot: URL, program: String, paths: CachePaths = .default) {
        let dashed = program.split(separator: "/").joined(separator: "-")
        let name = (dashed.isEmpty || dashed == ".") ? "main" : dashed
        fileURL = paths.answersFolder(moduleRoot: moduleRoot).appendingPathComponent(name + ".json")
    }

    /// All saved entries, oldest first; empty when the file is missing or unreadable.
    public func all() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Entry].self, from: data)) ?? []
    }

    /// The saved entry for a question.
    public func entry(for question: String) -> Entry? {
        all().last { $0.question == question }
    }

    /// Saves an entry, replacing the one with the same question.
    public func save(_ entry: Entry) throws {
        var entries = all().filter { $0.question != entry.question }
        entries.append(entry)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: fileURL, options: .atomic)
    }
}
