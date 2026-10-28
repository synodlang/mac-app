import CoreServices
import Foundation

/// Watches a module folder with FSEvents and reports changed paths that matter to a run:
/// `*.synod`, `synod.mod` and anything under `vendor/`, ignoring `out/` and dot folders.
///
/// `events` yields batches of module-relative paths (latency 100 ms). It is meant for one consumer.
public final class FileWatcher: @unchecked Sendable {
    public let events: AsyncStream<Set<String>>

    private let continuation: AsyncStream<Set<String>>.Continuation
    private let queue = DispatchQueue(label: "io.github.synodlang.synod.filewatcher")
    private let rootPath: String
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 0.1) {
        let resolved = Self.realPath(root.path)
        rootPath = resolved.hasSuffix("/") && resolved.count > 1 ? String(resolved.dropLast()) : resolved
        let (stream, continuation) = AsyncStream<Set<String>>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            watcher.handle(Array(paths.prefix(count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [rootPath] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            continuation.finish()
            return
        }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    /// The path with all symlinks resolved (`/var` becomes `/private/var`, as FSEvents reports).
    public static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }

    private func handle(_ paths: [String]) {
        var relevant: Set<String> = []
        for p in paths {
            guard p.hasPrefix(rootPath + "/") else { continue }
            let rel = String(p.dropFirst(rootPath.count + 1))
            if Self.isRelevant(rel) { relevant.insert(rel) }
        }
        if !relevant.isEmpty { continuation.yield(relevant) }
    }

    /// True for a module-relative path a run depends on.
    static func isRelevant(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/")
        guard let last = parts.last else { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if parts.first == "vendor" { return true }
        if parts.dropLast().contains("out") { return false }
        return last.hasSuffix(".synod") || (parts.count == 1 && last == "synod.mod")
    }

    /// Stops watching and ends `events`.
    public func stop() {
        queue.sync {
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                stream = nil
            }
        }
        continuation.finish()
    }

    deinit { stop() }
}
