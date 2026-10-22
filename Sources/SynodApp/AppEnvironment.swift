import Foundation
import Observation
import SynodCore

/// Where the compiler and the bundled examples are, shared by the app and the headless modes.
enum AppTools {
    /// The bundle's tools when usable, else the repository's `.deps`; a settings path replaces the compiler.
    static func resolve(override: String? = nil) -> ToolPaths? {
        var base: ToolPaths?
        // A run from the build folder (not an .app) uses the repository's pinned tools first.
        let inBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if !inBundle, let r = ToolPaths.repoDeps() {
            base = r
        } else if let b = ToolPaths.bundled(), b.isUsable {
            base = b
        } else {
            base = ToolPaths.repoDeps()
        }
        guard var tools = base else {
            if let o = override, !o.isEmpty { return ToolPaths(synod: URL(fileURLWithPath: o)).overriding(synodPath: o) }
            return nil
        }
        tools = tools.overriding(synodPath: override)
        return tools
    }
}

/// App-wide state: the compiler, its version check, the recent workspaces.
@MainActor @Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    static let overrideKey = "synodPathOverride"
    static let recentsKey = "recentWorkspaces"

    private(set) var tools: ToolPaths?
    private(set) var runner: SynodRunner?
    private(set) var version: SynodVersion?
    private(set) var versionProblem: String?
    private(set) var recents: [String]
    private var probed = false

    var synodPathOverride: String {
        didSet {
            UserDefaults.standard.set(synodPathOverride, forKey: Self.overrideKey)
            reload()
        }
    }

    private init() {
        synodPathOverride = UserDefaults.standard.string(forKey: Self.overrideKey) ?? ""
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        configureTools()
    }

    private func configureTools() {
        tools = AppTools.resolve(override: synodPathOverride)
        if let t = tools, t.isUsable {
            runner = SynodRunner(executable: t.synod)
        } else {
            runner = nil
        }
    }

    func reload() {
        configureTools()
        probed = false
        version = nil
        versionProblem = nil
        probeIfNeeded()
    }

    func probeIfNeeded() {
        guard !probed else { return }
        probed = true
        guard let runner else {
            versionProblem = "The synod compiler was not found. Set its path in Settings."
            return
        }
        Task {
            do {
                let v = try await SynodVersion.probe(runner)
                version = v
                versionProblem = v.problem
            } catch {
                versionProblem = "Could not run the compiler: \(error.localizedDescription)"
            }
        }
    }

    var examplesURL: URL? { tools?.examples }

    func addRecent(_ url: URL) {
        let p = url.standardizedFileURL.path
        recents.removeAll { $0 == p }
        recents.insert(p, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }
}

/// A workspace path given on the command line (`Synod.app --args <folder>`), if any.
enum LaunchArguments {
    /// Never shown; stands in for "no workspace" in the workspace window group.
    static let placeholder = URL(fileURLWithPath: "/dev/null")

    /// Set once the launch folder has been opened, so it is not opened again.
    @MainActor static var routed = false

    static var workspaceURL: URL? { workspaceURL(in: Array(CommandLine.arguments.dropFirst())) }

    /// The first argument that is not an option (or macOS's `-NS...` defaults pairs) and names an existing path.
    static func workspaceURL(in args: [String], exists: (String) -> Bool? = isDirectory) -> URL? {
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if a.hasPrefix("-") { skipNext = a.hasPrefix("-NS") || a.hasPrefix("-Apple"); continue }
            let path = (a as NSString).expandingTildeInPath
            if let isDir = exists(path) { return URL(fileURLWithPath: path, isDirectory: isDir) }
        }
        return nil
    }

    nonisolated static func isDirectory(_ path: String) -> Bool? {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) ? isDir.boolValue : nil
    }
}
