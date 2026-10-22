import Foundation

/// Locates the player script and the Web/ pages. Nothing is a SwiftPM resource:
/// the app finds them in Contents/Resources, tests and debug runs in the repository.
public struct WebAssets: Sendable {
    public let playerScriptURL: URL
    public let webDirectory: URL

    public init(playerScriptURL: URL, webDirectory: URL) {
        self.playerScriptURL = playerScriptURL
        self.webDirectory = webDirectory
    }

    /// App layout: `<base>/player/synod-player.iife.js` and `<base>/web/*`.
    public init(baseURL: URL) {
        self.init(
            playerScriptURL: baseURL.appendingPathComponent("player/synod-player.iife.js"),
            webDirectory: baseURL.appendingPathComponent("web", isDirectory: true))
    }

    /// Repository layout: `.deps/player/synod-player.iife.js` and `Web/`.
    public static func repository(root: URL? = nil) -> WebAssets {
        let root = root ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return WebAssets(
            playerScriptURL: root.appendingPathComponent(".deps/player/synod-player.iife.js"),
            webDirectory: root.appendingPathComponent("Web", isDirectory: true))
    }

    /// The bundle's Resources when they hold the player, else the repository.
    public static func locate() -> WebAssets {
        if let res = Bundle.main.resourceURL {
            let bundled = WebAssets(baseURL: res)
            if FileManager.default.fileExists(atPath: bundled.playerScriptURL.path) { return bundled }
        }
        return repository()
    }

    public var isComplete: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: playerScriptURL.path)
            && ["stage.html", "stage.js", "export.html", "export.js", "compare.html", "compare.js"].allSatisfy {
                fm.fileExists(atPath: webDirectory.appendingPathComponent($0).path)
            }
    }

    public func playerScript() throws -> String { try String(contentsOf: playerScriptURL, encoding: .utf8) }
    public func stageHTML() throws -> String { try read("stage.html") }
    public func stageJS() throws -> String { try read("stage.js") }
    public func exportHTML() throws -> String { try read("export.html") }
    public func exportJS() throws -> String { try read("export.js") }
    public func compareHTML() throws -> String { try read("compare.html") }
    public func compareJS() throws -> String { try read("compare.js") }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: webDirectory.appendingPathComponent(name), encoding: .utf8)
    }
}
