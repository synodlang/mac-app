import CryptoKit
import Foundation

/// Where the app keeps run outputs (a cache, never the workspace's `out/`) and Predict answers.
public struct CachePaths: Sendable, Equatable {
    /// `~/Library/Caches/io.github.synodlang.synod` by default.
    public var cacheRoot: URL
    /// `~/Library/Application Support/Synod` by default.
    public var supportRoot: URL

    public init(cacheRoot: URL, supportRoot: URL) {
        self.cacheRoot = cacheRoot
        self.supportRoot = supportRoot
    }

    public static var `default`: CachePaths {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return CachePaths(cacheRoot: caches.appendingPathComponent("io.github.synodlang.synod"),
                          supportRoot: support.appendingPathComponent("Synod"))
    }

    /// Both roots under one folder (for tests).
    public static func under(_ folder: URL) -> CachePaths {
        CachePaths(cacheRoot: folder.appendingPathComponent("caches"), supportRoot: folder.appendingPathComponent("support"))
    }

    /// First 16 hex digits of the SHA-256 of `text`.
    public static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `runs/<sha256(moduleRoot|program)[0..16]>`: the folder of all runs of a program.
    public func programRunsFolder(moduleRoot: URL, program: String) -> URL {
        cacheRoot.appendingPathComponent("runs").appendingPathComponent(Self.shortHash(moduleRoot.standardizedFileURL.path + "|" + program))
    }

    private static let lock = NSLock()

    /// Creates the next `run-<generation>` folder of a program and removes all but the last two.
    public func makeRunFolder(moduleRoot: URL, program: String) throws -> URL {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let base = programRunsFolder(moduleRoot: moduleRoot, program: program)
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let existing = Self.generations(in: base)
        let next = (existing.map(\.0).max() ?? 0) + 1
        let dir = base.appendingPathComponent("run-\(next)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (_, url) in existing.sorted(by: { $0.0 < $1.0 }).dropLast(1) {
            try? fm.removeItem(at: url)
        }
        return dir
    }

    /// The `run-N` folders in `base` as (N, url).
    public static func generations(in base: URL) -> [(Int, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("run-"), let n = Int(name.dropFirst(4)) else { return nil }
            return (n, base.appendingPathComponent(name))
        }
    }

    /// `answers/<sha256(moduleRoot)[0..16]>` under Application Support.
    public func answersFolder(moduleRoot: URL) -> URL {
        supportRoot.appendingPathComponent("answers").appendingPathComponent(Self.shortHash(moduleRoot.standardizedFileURL.path))
    }
}
