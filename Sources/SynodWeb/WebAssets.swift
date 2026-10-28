import Foundation
import WebKit

/// Locates the player script and the Web/ pages. Nothing is a SwiftPM resource:
/// the app finds them in Contents/Resources, tests and debug runs in the repository.
public struct WebAssets: Sendable {
    public let playerScriptURL: URL
    public let webDirectory: URL
    /// The unpacked fonts asset (`fonts/Inter.woff2`, ...), mounted as the players' `fontBase` (decision 118).
    public let fontsDirectory: URL?

    public init(playerScriptURL: URL, webDirectory: URL, fontsDirectory: URL? = nil) {
        self.playerScriptURL = playerScriptURL
        self.webDirectory = webDirectory
        self.fontsDirectory = fontsDirectory
    }

    /// App layout: `<base>/player/synod-player.iife.js` and `<base>/web/*`.
    public init(baseURL: URL) {
        self.init(
            playerScriptURL: baseURL.appendingPathComponent("player/synod-player.iife.js"),
            webDirectory: baseURL.appendingPathComponent("web", isDirectory: true),
            fontsDirectory: baseURL.appendingPathComponent("fonts", isDirectory: true))
    }

    /// Repository layout: `.deps/player/synod-player.iife.js` and `Web/`.
    public static func repository(root: URL? = nil) -> WebAssets {
        let root = root ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return WebAssets(
            playerScriptURL: root.appendingPathComponent(".deps/player/synod-player.iife.js"),
            webDirectory: root.appendingPathComponent("Web", isDirectory: true),
            fontsDirectory: root.appendingPathComponent(".deps/fonts", isDirectory: true))
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

    /// A script run before the page's own: sets `window.synodFontBase` to the fonts folder URL (or leaves it unset).
    public func fontPrelude() -> String {
        guard let dir = fontsDirectory,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("Inter.woff2").path) else { return "" }
        let url = dir.standardizedFileURL.absoluteString
        let data = (try? JSONSerialization.data(withJSONObject: [url], options: [])) ?? Data()
        let arr = String(decoding: data, as: UTF8.self)
        return "window.synodFontBase = \(arr)[0];"
    }

    /// The folder the web view may read: the common parent of the page folder and the fonts folder.
    public var readAccessRoot: URL {
        guard let f = fontsDirectory else { return webDirectory }
        let a = webDirectory.standardizedFileURL.pathComponents, b = f.standardizedFileURL.pathComponents
        var n = 0
        while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(a[0..<max(n, 1)])), isDirectory: true)
    }

    /// Loads a page of the Web folder from its file URL, so the fonts folder can be read.
    @MainActor
    public func load(_ page: String, in webView: WKWebView) {
        webView.loadFileURL(webDirectory.appendingPathComponent(page), allowingReadAccessTo: readAccessRoot)
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
