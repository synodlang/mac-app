import Foundation

/// The output of `synod version`: `language 0.2`, `compiler v0.2.4 (...)`, `formats a b c`.
public struct SynodVersion: Sendable, Equatable {
    public let language: String
    public let compiler: String
    public let formats: [String]

    /// The language version this app implements.
    public static let requiredLanguage = "0.2"
    /// The formats this app reads.
    public static let requiredFormats = ["synod-trace/1", "synod-scene/1", "synod-check/1"]

    public static func parse(_ output: String) -> SynodVersion {
        var language = ""
        var compiler = ""
        var formats: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            let rest = words[1].trimmingCharacters(in: .whitespaces)
            switch words[0] {
            case "language": language = rest
            case "compiler": compiler = rest
            case "formats": formats = rest.split(separator: " ").map(String.init)
            default: break
            }
        }
        return SynodVersion(language: language, compiler: compiler, formats: formats)
    }

    /// Why this compiler cannot be used, or nil when it speaks language 0.2 and the three formats.
    public var problem: String? {
        if language != Self.requiredLanguage {
            return "This app needs Synod language \(Self.requiredLanguage), but the compiler reports \(language.isEmpty ? "no language version" : language)."
        }
        let missing = Self.requiredFormats.filter { !formats.contains($0) }
        if !missing.isEmpty {
            return "The compiler does not write the formats \(missing.joined(separator: ", "))."
        }
        return nil
    }

    public var isCompatible: Bool { problem == nil }

    /// Runs `synod version` with `runner` and parses it.
    public static func probe(_ runner: SynodRunner) async throws -> SynodVersion {
        let r = try await runner.exec(["version"], cwd: FileManager.default.temporaryDirectory)
        guard r.exitCode == 0 else {
            throw PipelineError.toolFailed(exitCode: r.exitCode, stderr: r.stderrText)
        }
        return parse(r.stdoutText)
    }
}
