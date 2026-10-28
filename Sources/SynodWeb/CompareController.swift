import AppKit
import Foundation
import Observation
import WebKit

public enum CompareSide: String, Sendable, Equatable {
    case left, right
}

/// How the right run follows the left one.
public enum CompareSync: String, Sendable, Equatable {
    /// By simulated time, through each run's sync map.
    case sim
    /// By presentation time: the right run shows min(left time, its duration).
    case presentation
}

/// One knot of a sync map: simulated time (microseconds) and presentation time (ms).
/// A run's knots are monotone in both and start at (0, 0).
public struct SyncKnot: Sendable, Equatable {
    public var simMicros: Double
    public var at: Double
    public init(simMicros: Double, at: Double) { self.simMicros = simMicros; self.at = at }
}

/// What the compare page reports after loading the two scenes.
public struct CompareInfo: Sendable, Equatable {
    public let durationLeft: Double
    public let durationRight: Double
    public let warningsLeft: [String]
    public let warningsRight: [String]
    public let playing: Bool
    public let rate: Double
    public let sync: CompareSync
}

/// The shared clock of the compare page: simulated time T (microseconds, left run) and each side's
/// presentation time (ms).
public struct CompareTimes: Sendable, Equatable {
    public let simMicros: Double
    public let atLeft: Double
    public let atRight: Double
}

/// A message from the compare page. Markers, play and pause come from the left (driving) side.
public enum CompareEvent: Sendable, Equatable {
    case ready
    case time(CompareTimes)
    case marker(kind: String, at: Double, text: String, choices: [String])
    case play
    case pause(reason: PauseReason)
    case click(side: CompareSide, x: Double, y: Double, hit: StageHit?)
    case scene(durationLeft: Double, durationRight: Double)
    case error(String)

    public static func decode(_ body: Any) -> CompareEvent? {
        guard let dict = body as? [String: Any], let name = dict["event"] as? String else { return nil }
        switch name {
        case "time":
            guard let T = PlayerEvent.number(dict["T"]), let l = PlayerEvent.number(dict["atL"]),
                  let r = PlayerEvent.number(dict["atR"]) else { return nil }
            return .time(CompareTimes(simMicros: T, atLeft: l, atRight: r))
        case "click":
            guard let x = PlayerEvent.number(dict["x"]), let y = PlayerEvent.number(dict["y"]),
                  let side = (dict["side"] as? String).flatMap(CompareSide.init(rawValue:)) else { return nil }
            return .click(side: side, x: x, y: y, hit: StageHit.decode(dict["hit"]))
        case "scene":
            return .scene(
                durationLeft: PlayerEvent.number(dict["durationL"]) ?? 0,
                durationRight: PlayerEvent.number(dict["durationR"]) ?? 0)
        default:
            switch PlayerEvent.decode(body) {
            case .ready: return .ready
            case .marker(let k, let at, let text, let choices): return .marker(kind: k, at: at, text: text, choices: choices)
            case .play: return .play
            case .pause(let r): return .pause(reason: r)
            case .error(let m): return .error(m)
            default: return nil
            }
        }
    }
}

/// Observable mirror of the compare page.
@MainActor @Observable
public final class CompareState {
    public internal(set) var ready = false
    public internal(set) var times = CompareTimes(simMicros: 0, atLeft: 0, atRight: 0)
    public internal(set) var playing = false
    public internal(set) var lastMarker: CompareEvent?
    public internal(set) var lastError: String?

    func apply(_ event: CompareEvent) {
        switch event {
        case .ready: ready = true
        case .time(let t): times = t
        case .marker: lastMarker = event
        case .play: playing = true
        case .pause: playing = false
        case .error(let m): lastError = m
        case .click, .scene: break
        }
    }
}

/// Owns the WKWebView of the compare page: two players side by side, the left one driving, the right
/// one seeked to the matching time on every animation frame (decision 83). All page calls go through
/// callAsyncJavaScript with arguments.
@MainActor
public final class CompareController {
    public let webView: WKWebView
    public let state = CompareState()
    /// Page events. Single consumer.
    public let events: AsyncStream<CompareEvent>

    private let continuation: AsyncStream<CompareEvent>.Continuation
    private var window: NSWindow?
    private var isReady = false
    private var failure: String?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var handler: ScriptHandler?

    public init(assets: WebAssets, size: CGSize = CGSize(width: 1200, height: 600), offscreenWindow: Bool = false) throws {
        let (stream, cont) = AsyncStream.makeStream(of: CompareEvent.self, bufferingPolicy: .bufferingNewest(2048))
        events = stream
        continuation = cont

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: assets.fontPrelude(), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: try assets.playerScript(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: try assets.compareJS(), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))

        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        let h = ScriptHandler { [weak self] body in self?.receive(body) }
        ucc.add(h, contentWorld: .page, name: "synodHost")
        handler = h
        if offscreenWindow {
            let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = webView
            w.orderFrontRegardless()
            window = w
        }
        assets.load("compare.html", in: webView)
    }

    public func tearDown() {
        continuation.finish()
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.removeScriptMessageHandler(forName: "synodHost", contentWorld: .page)
        handler = nil
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
        guard let event = CompareEvent.decode(body) else { return }
        if event == .ready {
            isReady = true
            let waiting = waiters
            waiters = []
            for w in waiting { w.resume() }
        }
        state.apply(event)
        continuation.yield(event)
    }

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

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await waitUntilReady()
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            throw StageError.script(StageController.message(error))
        }
    }

    private func info(from any: Any?) throws -> CompareInfo {
        guard let d = any as? [String: Any], let dl = PlayerEvent.number(d["durationL"]),
              let dr = PlayerEvent.number(d["durationR"]), let rate = PlayerEvent.number(d["rate"]) else {
            throw StageError.badResult("compare info")
        }
        return CompareInfo(
            durationLeft: dl, durationRight: dr,
            warningsLeft: (d["warningsL"] as? [String]) ?? [], warningsRight: (d["warningsR"] as? [String]) ?? [],
            playing: (d["playing"] as? Bool) ?? false, rate: rate,
            sync: (d["sync"] as? String).flatMap(CompareSync.init(rawValue:)) ?? .sim)
    }

    /// Loads both scenes with their sync maps and shows the left poster frame. Throws
    /// StageError.script with the player's message on a bad scene.
    @discardableResult
    public func setScenes(
        left: String, right: String, knotsLeft: [SyncKnot], knotsRight: [SyncKnot]
    ) async throws -> CompareInfo {
        try info(from: try await call(
            "return window.compare.setScenes(l, r, kl, kr);",
            ["l": left, "r": right,
             "kl": knotsLeft.map { [$0.simMicros, $0.at] }, "kr": knotsRight.map { [$0.simMicros, $0.at] }]))
    }

    public func compareInfo() async throws -> CompareInfo { try info(from: try await call("return window.compare.info();")) }
    public func play() async throws { try await call("window.compare.play();") }
    public func pause() async throws { try await call("window.compare.pause();") }
    /// Seeks both runs to simulated time `micros` of the left run.
    public func seekSim(_ micros: Double) async throws { try await call("window.compare.seekSim(T);", ["T": micros]) }
    /// Seeks the left run to presentation time `at` (ms); the right one follows.
    public func seek(to at: Double) async throws { try await call("window.compare.seek(at);", ["at": at]) }
    public func setRate(_ rate: Double) async throws { try await call("window.compare.setRate(r);", ["r": rate]) }
    public func setSync(_ mode: CompareSync) async throws { try await call("window.compare.setSync(m);", ["m": mode.rawValue]) }
    /// Exchanges the runs (the new left drives) at the same simulated time.
    public func swap() async throws { try await call("window.compare.swap();") }

    public func hitTest(side: CompareSide, x: Double, y: Double) async throws -> StageHit? {
        StageHit.decode(try await call("return window.compare.hitTest(s, x, y);", ["s": side.rawValue, "x": x, "y": y]))
    }

    public func nodeBounds(side: CompareSide) async throws -> [StageNodeBox] {
        let r = try await call("return window.compare.nodeBounds(s);", ["s": side.rawValue])
        return (r as? [Any])?.compactMap(StageNodeBox.decode) ?? []
    }

    /// Outlines the named node on both sides (nil clears it).
    public func setSelection(_ node: String?) async throws {
        try await call("window.compare.setSelection(node);", ["node": node ?? NSNull()])
    }

    public func times() async throws -> CompareTimes {
        guard let d = try await call("return window.compare.times();") as? [String: Any],
              let T = PlayerEvent.number(d["T"]), let l = PlayerEvent.number(d["atL"]), let r = PlayerEvent.number(d["atR"])
        else { throw StageError.badResult("compare times") }
        return CompareTimes(simMicros: T, atLeft: l, atRight: r)
    }

    /// A snapshot of what the web view shows, as pixels.
    public func snapshotImage() async throws -> BGRAImage {
        let image: NSImage = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw StageError.badResult("snapshot") }
        return try PixelBuffers.decodePNG(png)
    }
}
