import AppKit
import Foundation
import Observation
import WebKit

public enum StageError: Error, CustomStringConvertible {
    case notReady(String)
    case script(String)
    case badResult(String)

    public var description: String {
        switch self {
        case .notReady(let m): return "stage not ready: \(m)"
        case .script(let m): return "stage script error: \(m)"
        case .badResult(let m): return "unexpected stage result: \(m)"
        }
    }
}

/// An entry of the scene's trace: a fact (trace seq) at a presentation time (ms).
public struct StageFact: Sendable, Equatable {
    public let seq: Int
    public let at: Double
}

/// What the page reports after loading a scene.
public struct StageInfo: Sendable, Equatable {
    public let duration: Double
    public let time: Double
    public let playing: Bool
    public let rate: Double
    public let warnings: [String]
}

/// Observable mirror of the player, updated from the bridge events.
@MainActor @Observable
public final class PlayerState {
    public internal(set) var ready = false
    public internal(set) var time: Double = 0
    public internal(set) var playing = false
    public internal(set) var rate: Double = 1
    public internal(set) var duration: Double = 0
    public internal(set) var factSeq: Int?
    public internal(set) var lastMarker: PlayerEvent?
    public internal(set) var lastError: String?
    /// Wall-clock moment of the last `time` event, for smoothing between 30 Hz events.
    public internal(set) var lastTimeWall: Date = .now

    func apply(_ event: PlayerEvent) {
        switch event {
        case .ready: ready = true
        case .time(let at): time = at; lastTimeWall = .now
        case .marker: lastMarker = event
        case .fact(let seq, _): factSeq = seq
        case .play: playing = true
        case .pause: playing = false
        case .scene: break
        case .error(let m): lastError = m
        }
    }
}

@MainActor
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    let onMessage: (Any) -> Void
    init(_ onMessage: @escaping (Any) -> Void) { self.onMessage = onMessage }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}

/// Owns a WKWebView running the player. All page calls go through
/// callAsyncJavaScript with arguments; nothing is built by string interpolation.
@MainActor
public final class StageController {
    public let webView: WKWebView
    public let state = PlayerState()
    /// Bridge and host events. Single consumer.
    public let events: AsyncStream<PlayerEvent>

    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var window: NSWindow?
    private var isReady = false
    private var failure: String?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// - Parameters:
    ///   - size: the web view size in points.
    ///   - offscreenWindow: host the view in a borderless window far off screen, which keeps
    ///     WebKit from throttling an un-windowed view.
    public init(assets: WebAssets, size: CGSize = CGSize(width: 960, height: 600), offscreenWindow: Bool = false) throws {
        let (stream, cont) = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .bufferingNewest(2048))
        events = stream
        continuation = cont

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: try assets.playerScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: try assets.stageJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        let html = try assets.stageHTML()

        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let handler = ScriptHandler { [weak self] body in self?.receive(body) }
        ucc.add(handler, contentWorld: .page, name: "synodPlayer")
        ucc.add(handler, contentWorld: .page, name: "synodHost")
        handlers = handler

        if offscreenWindow {
            let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = webView
            w.orderFrontRegardless()
            window = w
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    private var handlers: ScriptHandler?

    /// Detaches handlers and closes the hosting window. Call when done.
    public func tearDown() {
        continuation.finish()
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.removeScriptMessageHandler(forName: "synodPlayer", contentWorld: .page)
        ucc.removeScriptMessageHandler(forName: "synodHost", contentWorld: .page)
        handlers = nil
        window?.close()
        window = nil
        let waiting = waiters
        waiters = []
        for w in waiting { w.resume(throwing: StageError.notReady("torn down")) }
    }

    private func receive(_ body: Any) {
        if let dict = body as? [String: Any], dict["event"] as? String == "error", dict["fatal"] as? Bool == true {
            failure = (dict["message"] as? String) ?? "fatal error"
            let waiting = waiters
            waiters = []
            for w in waiting { w.resume(throwing: StageError.notReady(failure!)) }
        }
        guard let event = PlayerEvent.decode(body) else { return }
        if event == .ready {
            isReady = true
            let waiting = waiters
            waiters = []
            for w in waiting { w.resume() }
        }
        state.apply(event)
        continuation.yield(event)
    }

    /// Waits for the page's `ready` message (player mounted, fonts loaded).
    public func waitUntilReady(timeout: Duration = .seconds(20)) async throws {
        if isReady { return }
        if let failure { throw StageError.notReady(failure) }
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.timeoutWaiters()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
        }
    }

    private func timeoutWaiters() {
        let waiting = waiters
        waiters = []
        for w in waiting { w.resume(throwing: StageError.notReady("timed out")) }
    }

    // MARK: Page calls

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await waitUntilReady()
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            throw StageError.script(Self.message(error))
        }
    }

    static func message(_ error: Error) -> String {
        let ns = error as NSError
        if let m = ns.userInfo["WKJavaScriptExceptionMessage"] as? String { return m }
        return ns.localizedDescription
    }

    private func info(from any: Any?) throws -> StageInfo {
        guard let d = any as? [String: Any],
              let duration = PlayerEvent.number(d["duration"]), let time = PlayerEvent.number(d["time"]),
              let rate = PlayerEvent.number(d["rate"]) else { throw StageError.badResult("info") }
        let info = StageInfo(
            duration: duration, time: time, playing: (d["playing"] as? Bool) ?? false, rate: rate,
            warnings: (d["warnings"] as? [String]) ?? [])
        state.duration = duration
        return info
    }

    private func fact(from any: Any?) -> StageFact? {
        guard let d = any as? [String: Any], let seq = PlayerEvent.number(d["seq"]), let at = PlayerEvent.number(d["at"])
        else { return nil }
        return StageFact(seq: Int(seq), at: at)
    }

    /// Loads scene.json text. Throws StageError.script with the player's message on a bad scene.
    @discardableResult
    public func setScene(_ text: String, keepTime: Bool = true) async throws -> StageInfo {
        try info(from: try await call("return window.stage.setScene(text, keepTime);", ["text": text, "keepTime": keepTime]))
    }

    public func stageInfo() async throws -> StageInfo {
        try info(from: try await call("return window.stage.info();"))
    }

    public func play() async throws { try await call("window.stage.play();") }
    public func pause() async throws { try await call("window.stage.pause();") }
    public func seek(to at: Double) async throws { try await call("window.stage.seek(at);", ["at": at]) }
    public func setRate(_ rate: Double) async throws { try await call("window.stage.setRate(rate);", ["rate": rate]) }
    public func setStopAtPause(_ on: Bool) async throws { try await call("window.stage.setStopAtPause(on);", ["on": on]) }

    /// The next fact after the current time; pauses and seeks to it. nil at the end.
    public func nextFact() async throws -> StageFact? { fact(from: try await call("return window.stage.nextFact();")) }
    public func prevFact() async throws -> StageFact? { fact(from: try await call("return window.stage.prevFact();")) }
    public func factAt(_ at: Double) async throws -> StageFact? {
        fact(from: try await call("return window.stage.factAt(at);", ["at": at]))
    }
    public func timeOfSeq(_ seq: Int) async throws -> Double? {
        PlayerEvent.number(try await call("return window.stage.timeOfSeq(seq);", ["seq": seq]))
    }

    /// PNG of the stage drawn at `at` ms into a width x height css-pixel canvas at `pixelRatio`.
    /// Pauses playback.
    public func renderFramePNG(at: Double, width: Int, height: Int, pixelRatio: Double = 1) async throws -> Data {
        let r = try await call(
            "return await window.stage.renderFramePNG(at, w, h, pr);",
            ["at": at, "w": width, "h": height, "pr": pixelRatio])
        guard let b64 = r as? String, let data = Data(base64Encoded: b64) else { throw StageError.badResult("png") }
        return data
    }

    /// A snapshot of what the web view shows, as pixels.
    public func snapshotImage() async throws -> BGRAImage {
        let config = WKSnapshotConfiguration()
        let image: NSImage = try await webView.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw StageError.badResult("snapshot") }
        return try PixelBuffers.decodePNG(png)
    }
}
