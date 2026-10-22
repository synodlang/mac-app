import Foundation

/// A Synod module: a folder tree with a `synod.mod` at its root.
public struct Workspace: Sendable, Hashable {
    /// A folder whose main file starts with `# package main`.
    public struct Program: Sendable, Hashable, Identifiable {
        /// Folder relative to the module root with `/` separators; `.` for the root itself.
        public let relPath: String
        /// File name of the main file inside the folder.
        public let mainFile: String
        public init(relPath: String, mainFile: String) {
            self.relPath = relPath
            self.mainFile = mainFile
        }
        public var id: String { relPath }
        /// Last path component, for display.
        public var name: String { relPath == "." ? "main" : String(relPath.split(separator: "/").last ?? "") }
    }

    /// A folder of `.synod` files without a main file (a library package).
    public struct Package: Sendable, Hashable, Identifiable {
        public let relPath: String
        /// Names of the `.synod` files, sorted.
        public let files: [String]
        public var id: String { relPath }
        public var name: String { relPath == "." ? "package" : String(relPath.split(separator: "/").last ?? "") }
    }

    /// What `scan()` found.
    public struct Scan: Sendable, Equatable {
        public var programs: [Program]
        public var packages: [Package]
    }

    public enum OpenError: Error, Equatable, LocalizedError {
        case notAWorkspace
        public var errorDescription: String? { "Not a Synod workspace (no synod.mod)" }
    }

    /// The module root: the folder holding `synod.mod`.
    public let root: URL
    /// The `module` directive, e.g. `github.com/synodlang/examples`.
    public let modulePath: String
    /// The `synod` directive (language version), e.g. `0.2`.
    public let languageVersion: String
    /// The `require` directives, `module version` each.
    public let requires: [String]

    /// Folder names that are never scanned (besides names starting with `.` or `_`).
    public static let skippedFolders: Set<String> = ["testdata", "vendor", "out"]

    /// Opens the workspace containing `url` (a folder or a file) by walking up to the first `synod.mod`.
    public static func open(_ url: URL) throws -> Workspace {
        var dir = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }
        while true {
            let mod = dir.appendingPathComponent("synod.mod")
            if FileManager.default.fileExists(atPath: mod.path) {
                let text = (try? String(contentsOf: mod, encoding: .utf8)) ?? ""
                return Workspace(root: dir, modFile: text)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { throw OpenError.notAWorkspace }
            dir = parent
        }
    }

    init(root: URL, modFile text: String) {
        self.root = root
        var module = ""
        var synod = ""
        var reqs: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = words.first else { continue }
            let args = words.dropFirst().joined(separator: " ")
            switch head {
            case "module": module = args
            case "synod": synod = args
            case "require": reqs.append(args)
            default: break
            }
        }
        modulePath = module
        languageVersion = synod
        requires = reqs
    }

    /// Finds the programs and packages under the root, skipping folders that start with `.` or `_`
    /// and `testdata`, `vendor`, `out`. Sorted by path.
    public func scan() -> Scan {
        var programs: [Program] = []
        var packages: [Package] = []
        visit(root, rel: ".", programs: &programs, packages: &packages)
        programs.sort { $0.relPath < $1.relPath }
        packages.sort { $0.relPath < $1.relPath }
        return Scan(programs: programs, packages: packages)
    }

    private func visit(_ dir: URL, rel: String, programs: inout [Program], packages: inout [Package]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var files: [String] = []
        var folders: [String] = []
        for name in names.sorted() {
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            let full = dir.appendingPathComponent(name).path
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if name.hasPrefix("_") || Self.skippedFolders.contains(name) { continue }
                if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { continue }
                folders.append(name)
            } else if name.hasSuffix(".synod") {
                files.append(name)
            }
        }
        if !files.isEmpty {
            if let main = files.first(where: { Self.isMainFile(dir.appendingPathComponent($0)) }) {
                programs.append(Program(relPath: rel, mainFile: main))
            } else {
                packages.append(Package(relPath: rel, files: files))
            }
        }
        for f in folders {
            visit(dir.appendingPathComponent(f), rel: rel == "." ? f : rel + "/" + f, programs: &programs, packages: &packages)
        }
    }

    private static func isMainFile(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) == "# package main"
    }

    /// The absolute URL of a module-relative path.
    public func url(forRelative path: String) -> URL {
        path == "." ? root : root.appendingPathComponent(path)
    }
}
