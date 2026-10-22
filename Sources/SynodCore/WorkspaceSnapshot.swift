import CryptoKit
import Foundation

/// The module's `.synod` files, `synod.mod` and `synod.sum` before Claude runs, so the changes
/// can be counted and reverted byte for byte (plan 1.6). Not followed: symbolic links, `vendor`,
/// `out`, and folders or files starting with `.` or `_`.
public struct WorkspaceSnapshot: Sendable, Equatable {
    public static let maxFileBytes = 1_000_000
    public static let maxTotalBytes = 20_000_000

    struct Entry: Sendable, Equatable {
        let digest: String
        /// nil when the file was over a limit.
        let data: Data?
    }

    public struct Diff: Sendable, Equatable {
        public var added: [String] = []
        public var modified: [String] = []
        public var deleted: [String] = []
        public var count: Int { added.count + modified.count + deleted.count }
        public var isEmpty: Bool { count == 0 }
        /// Added and modified files: the ones to reload from disk.
        public var changedOrAdded: [String] { (added + modified).sorted() }
    }

    public enum RevertError: Error, Equatable, LocalizedError {
        case notRestorable
        public var errorDescription: String? { "Revert is not available: the workspace was too large to snapshot." }
    }

    public let root: URL
    private let entries: [String: Entry]
    private let directories: Set<String>
    /// False when a file or the total went over the limits: Revert is off.
    public let canRevert: Bool

    public var fileCount: Int { entries.count }
    public var paths: [String] { entries.keys.sorted() }

    /// Snapshots the module at `root`.
    public static func take(root: URL, maxFileBytes: Int = maxFileBytes, maxTotalBytes: Int = maxTotalBytes) -> WorkspaceSnapshot {
        let (files, dirs) = scan(root: root)
        var entries: [String: Entry] = [:]
        var total = 0
        var ok = true
        for rel in files.keys.sorted() {
            guard let data = try? Data(contentsOf: files[rel]!) else { ok = false; continue }
            let digest = hash(data)
            if data.count > maxFileBytes || total + data.count > maxTotalBytes {
                ok = false
                entries[rel] = Entry(digest: digest, data: nil)
            } else {
                total += data.count
                entries[rel] = Entry(digest: digest, data: data)
            }
        }
        return WorkspaceSnapshot(root: root, entries: entries, directories: dirs, canRevert: ok)
    }

    /// What changed on disk since the snapshot.
    public func diff() -> Diff {
        let (files, _) = Self.scan(root: root)
        var d = Diff()
        for rel in files.keys.sorted() {
            guard let e = entries[rel] else { d.added.append(rel); continue }
            if let data = try? Data(contentsOf: files[rel]!), Self.hash(data) != e.digest { d.modified.append(rel) }
        }
        d.deleted = entries.keys.filter { files[$0] == nil }.sorted()
        return d
    }

    /// Restores the snapshot's bytes, recreates deleted files and deletes added files (and the
    /// folders they leave empty that the snapshot did not have). Returns what was undone.
    @discardableResult
    public func revert() throws -> Diff {
        guard canRevert else { throw RevertError.notRestorable }
        let d = diff()
        let fm = FileManager.default
        for rel in d.added {
            try fm.removeItem(at: root.appendingPathComponent(rel))
            var parent = (rel as NSString).deletingLastPathComponent
            while !parent.isEmpty, !directories.contains(parent) {
                let url = root.appendingPathComponent(parent)
                guard (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { break }
                try fm.removeItem(at: url)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for rel in d.modified + d.deleted {
            guard let data = entries[rel]?.data else { continue }
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return d
    }

    // MARK: walking

    private static func scan(root: URL) -> (files: [String: URL], dirs: Set<String>) {
        var files: [String: URL] = [:]
        var dirs: Set<String> = []
        let fm = FileManager.default
        func walk(_ rel: String) {
            let dir = rel.isEmpty ? root : root.appendingPathComponent(rel)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() {
                if name.hasPrefix(".") || name.hasPrefix("_") { continue }
                let url = dir.appendingPathComponent(name)
                let childRel = rel.isEmpty ? name : rel + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: url.path), let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    if name == "vendor" || name == "out" { continue }
                    dirs.insert(childRel)
                    walk(childRel)
                } else if type == .typeRegular {
                    if name.hasSuffix(".synod") || (rel.isEmpty && (name == "synod.mod" || name == "synod.sum")) {
                        files[childRel] = url
                    }
                }
            }
        }
        walk("")
        return (files, dirs)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
