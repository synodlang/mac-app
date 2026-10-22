import Foundation

/// Finds the user's `claude` and asks it for its version.
public enum ClaudeLocator {
    public static func candidates(home: String = NSHomeDirectory()) -> [URL] {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(fileURLWithPath: $0) }
    }

    /// The first executable candidate, or nil.
    public static func detect(home: String = NSHomeDirectory(), candidates: [URL]? = nil) -> URL? {
        let fm = FileManager.default
        return (candidates ?? Self.candidates(home: home)).first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// The path setting wins when it is non-empty (`~` expanded); otherwise auto-detection.
    /// The result is nil when nothing executable is found.
    public static func resolve(setting: String?, home: String = NSHomeDirectory()) -> URL? {
        if let s = setting?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return detect(home: home)
    }

    /// The first line of `claude --version`, or nil when it fails or takes longer than `timeout`.
    public static func version(of claude: URL, synod: URL, timeout: Duration = .seconds(5),
                               host: [String: String] = ProcessInfo.processInfo.environment) async -> String? {
        let proc = ClaudeProcess(
            executable: claude, arguments: ["--version"],
            environment: ClaudeInvocation.environment(host: host, synod: synod, claude: claude),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout, stopTiming: .init(sigtermAfter: .milliseconds(300), sigkillAfter: .milliseconds(300)))
        let collected = Collected()
        guard let exit = try? await proc.run(onLine: { collected.add($0) }),
              exit.status == 0, !exit.timedOut else { return nil }
        return collected.lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ l: String) { lock.lock(); _lines.append(l); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
