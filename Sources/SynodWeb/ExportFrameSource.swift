import AppKit
import Foundation
import WebKit

public struct ExportSceneInfo: Sendable, Equatable {
    public let duration: Double
    public let warnings: [String]
    public let pixelWidth: Int
    public let pixelHeight: Int
}

@MainActor
private final class LoadDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

/// Renders frames of one scene in its own web view and returns them as PNG data.
@MainActor
public final class ExportFrameSource {
    private let webView: WKWebView
    private let html: String
    private let delegate = LoadDelegate()
    private var window: NSWindow?
    private let sceneText: String
    private let width: Int
    private let height: Int
    private let pixelRatio: Double

    public convenience init(assets: WebAssets, sceneText: String, size: ExportSize, offscreenWindow: Bool = false) throws {
        try self.init(
            assets: assets, sceneText: sceneText, width: size.cssWidth, height: size.cssHeight,
            pixelRatio: size.pixelRatio, offscreenWindow: offscreenWindow)
    }

    /// A frame source with an explicit layout size (CSS px) and pixel ratio; a GIF uses
    /// the chosen width, the scene's aspect and ratio 1.
    public init(
        assets: WebAssets, sceneText: String, width: Int, height: Int, pixelRatio: Double = 1,
        offscreenWindow: Bool = false
    ) throws {
        self.sceneText = sceneText
        self.width = width
        self.height = height
        self.pixelRatio = pixelRatio
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: try assets.playerScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: try assets.exportJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        html = try assets.exportHTML()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = delegate
        if offscreenWindow {
            let w = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = webView
            w.orderFrontRegardless()
            window = w
        }
    }

    public func close() {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        window?.close()
        window = nil
    }

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            throw StageError.script(StageController.message(error))
        }
    }

    /// Loads the page and the scene. The scene text was captured when the source was created.
    public func prepare() async throws -> ExportSceneInfo {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            delegate.continuation = c
            webView.loadHTMLString(html, baseURL: nil)
        }
        let r = try await call(
            "return await window.exporter.init(text, w, h, pr);",
            ["text": sceneText, "w": width, "h": height, "pr": pixelRatio])
        guard let d = r as? [String: Any], let duration = PlayerEvent.number(d["duration"]),
              let pw = PlayerEvent.number(d["width"]), let ph = PlayerEvent.number(d["height"])
        else { throw StageError.badResult("export init") }
        return ExportSceneInfo(
            duration: duration, warnings: (d["warnings"] as? [String]) ?? [], pixelWidth: Int(pw), pixelHeight: Int(ph))
    }

    /// PNG frames for the given times, in order.
    public func frames(at times: [Double]) async throws -> [Data] {
        let r = try await call("return await window.exporter.frames(ats);", ["ats": times])
        guard let strings = r as? [String] else { throw StageError.badResult("frames") }
        return try await Task.detached {
            try strings.map { s in
                guard let d = Data(base64Encoded: s) else { throw StageError.badResult("base64") }
                return d
            }
        }.value
    }
}
