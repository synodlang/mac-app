import Foundation

/// Creates a workspace with the bundled compiler's `synod new <dir> [--module path] [--lib]`.
public enum NewWorkspace {
    public struct Request: Sendable, Equatable {
        /// The folder to create (or an empty existing one).
        public var directory: URL
        /// The module path; empty or nil means `defaultModule(forFolder:)`.
        public var module: String?
        /// A library: one package and no demo program.
        public var isLibrary: Bool

        public init(directory: URL, module: String? = nil, isLibrary: Bool = false) {
            self.directory = directory
            self.module = module
            self.isLibrary = isLibrary
        }
    }

    /// What was created.
    public struct Created: Sendable, Equatable {
        public var root: URL
        /// The package to show when the workspace has no program (a library), else nil.
        public var package: String?
        /// The program (folder relative to the root) the workspace opens on, else nil.
        public var program: String?
        /// The file to open in the editor, relative to the root.
        public var file: String?

        public init(root: URL, package: String? = nil, program: String? = nil, file: String? = nil) {
            self.root = root
            self.package = package
            self.program = program
            self.file = file
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notEmpty(String)
        case synod(String)

        public var errorDescription: String? {
            switch self {
            case .notEmpty(let path): return "\(path) already exists and is not empty. Choose a new folder name."
            case .synod(let message): return message
            }
        }
    }

    /// `example.com/<name>` with the folder name reduced to a lower-case word (`synod new` wants one),
    /// or `example.com/app` when nothing is left.
    public static func defaultModule(forFolder name: String) -> String {
        let word = name.lowercased().unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }
        return "example.com/" + (word.isEmpty ? "app" : String(String.UnicodeScalarView(word)))
    }

    /// The module path the request will use.
    public static func module(for request: Request) -> String {
        let trimmed = (request.module ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModule(forFolder: request.directory.lastPathComponent) : trimmed
    }

    /// The arguments of `synod new`, as an array (never a shell line).
    public static func arguments(for request: Request) -> [String] {
        var args = ["new", request.directory.path, "--module", module(for: request)]
        if request.isLibrary { args.append("--lib") }
        return args
    }

    /// True when a folder exists at `url` and holds anything (hidden files included).
    public static func isNonEmptyFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return true }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }

    /// The message of a failed `synod new`: its stderr (else stdout) without the `synod new:` prefix.
    public static func message(from result: ProcessResult) -> String {
        var text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.hasPrefix("synod new: ") { text.removeFirst("synod new: ".count) }
        return text.isEmpty ? "synod new failed with exit status \(result.exitCode)" : text
    }

    /// Runs `synod new` and works out what to open. Throws `Failure`, `RunnerError` or `Workspace.OpenError`.
    public static func create(_ request: Request, runner: SynodRunner) async throws -> Created {
        if isNonEmptyFolder(request.directory) { throw Failure.notEmpty(request.directory.path) }
        let parent = request.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let result = try await runner.exec(arguments(for: request), cwd: parent)
        guard result.exitCode == 0 else { throw Failure.synod(message(from: result)) }
        let root = URL(fileURLWithPath: FileWatcher.realPath(request.directory.path), isDirectory: true)
        let workspace = try Workspace.open(root)
        return created(root: root, scan: workspace.scan())
    }

    /// Picks the file to show: a program's main file (the demo), else the first package's first file.
    static func created(root: URL, scan: Workspace.Scan) -> Created {
        func rel(_ dir: String, _ file: String) -> String { dir == "." ? file : dir + "/" + file }
        if let p = scan.programs.first(where: { $0.mainFile == "demo.synod" }) ?? scan.programs.first {
            return Created(root: root, package: nil, program: p.relPath, file: rel(p.relPath, p.mainFile))
        }
        if let pkg = scan.packages.first, let f = pkg.files.first {
            return Created(root: root, package: pkg.relPath, program: nil, file: rel(pkg.relPath, f))
        }
        return Created(root: root, package: nil, program: nil, file: nil)
    }
}
