import AppKit
import Foundation
import Observation
import SynodCore

/// The editor of a workspace: open buffers, the checks that color them (decisions 78 to 81),
/// saving with `synod fmt`, quick fixes and go to definition. It never runs a program; the
/// file watcher and the run coordinator do that once a saved file changes.
@MainActor @Observable
final class EditorModel {
    typealias Origin = WorkspaceModel.Origin

    /// A request to scroll to and mark a span; the view acts on each new `serial` once.
    struct Reveal: Equatable {
        var serial: Int
        var file: String
        var origin: Origin
        var line: Int
        var col: Int
        var endLine: Int?
        var endCol: Int?
    }

    struct Definition: Equatable {
        var file: String
        var origin: Origin
        var line: Int
        var col: Int
    }

    enum SaveResult: Equatable {
        case saved(formatted: Bool)
        /// `synod fmt` refused the file (it has errors); the file stays as written.
        case formatRefused(output: String)
    }

    enum EditorError: Error, LocalizedError, Equatable {
        case readOnly(String)
        case noCompiler
        case stale
        case noFile(String)

        var errorDescription: String? {
            switch self {
            case .readOnly(let f): return "\(f) is read-only."
            case .noCompiler: return "The synod compiler was not found."
            case .stale: return "The fix is out of date: the text changed since the last check."
            case .noFile(let f): return "Cannot open \(f)."
            }
        }
    }

    let workspace: Workspace
    let examples: Workspace?
    /// True when the workspace itself is inside the bundled examples.
    let ownReadOnly: Bool

    @ObservationIgnored var runner: () -> SynodRunner?
    /// The program the stage shows: its check gives the diagnostics of the whole graph.
    @ObservationIgnored var programTarget: () -> (origin: Origin, relPath: String)? = { nil }
    @ObservationIgnored var cache: CachePaths = .default
    /// Set by the active text view: shows the fixes at the caret as a menu.
    @ObservationIgnored var presentFixes: (([EditorFix]) -> Void)?
    /// Runs after a file was saved (and formatted), for example to start a run.
    @ObservationIgnored var didSave: ((EditorDocument) -> Void)?
    /// Runs after a check covered `doc`'s file, with its report (completion refreshes its scope here).
    @ObservationIgnored var didCheck: ((EditorDocument, CheckReport) -> Void)?
    /// Set by the active text view: opens the completion list at the caret (⌃Space).
    @ObservationIgnored var triggerCompletion: (() -> Void)?
    /// Phrase completion of this editor, set by the workspace model.
    @ObservationIgnored var completion: CompletionController?
    /// True while a prompt-bar request runs: the user cannot type (Claude edits through the MCP tools).
    var userLocked = false

    /// Quiet time after the last keystroke before unsaved buffers are checked (decision 81).
    var debounce: Duration = .milliseconds(300)
    /// False in headless runs, which have no run-loop events to close undo groups.
    @ObservationIgnored var undoGroupsByEvent = true

    private(set) var documents: [String: EditorDocument] = [:]
    private(set) var current: EditorDocument?
    /// The latest check of the shown program, including unsaved buffers; the Problems list prefers it.
    private(set) var programReport: CheckReport?
    private(set) var programReportTarget: String?
    /// The latest check of the whole module including unsaved buffers (the editor MCP server's `get_diagnostics`).
    @ObservationIgnored private(set) var moduleReport: CheckReport?
    private(set) var reveal: Reveal?
    private(set) var isChecking = false
    /// Counts finished checks (headless runs and tests wait on it).
    private(set) var checkCount = 0
    var lastError: String?

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revealSerial = 0
    @ObservationIgnored private var saving: Set<String> = []
    @ObservationIgnored private weak var highlighted: EditorDocument?

    init(workspace: Workspace, examples: Workspace? = nil, ownReadOnly: Bool = false,
         runner: @escaping () -> SynodRunner?) {
        self.workspace = workspace
        self.examples = examples
        self.ownReadOnly = ownReadOnly
        self.runner = runner
    }

    func stop() {
        checkTask?.cancel()
        generation += 1
    }

    func workspace(for origin: Origin) -> Workspace? { origin == .own ? workspace : examples }

    static func key(_ file: String, _ origin: Origin) -> String { "\(origin.rawValue):\(file)" }

    static func folder(of file: String) -> String {
        let d = (file as NSString).deletingLastPathComponent
        return d.isEmpty ? "." : d
    }

    // MARK: Documents

    /// Whether a file is read-only: the bundled examples, a workspace inside them, vendored code.
    func isReadOnly(file: String, origin: Origin) -> Bool {
        origin == .examples || ownReadOnly || file.hasPrefix("vendor/")
    }

    @discardableResult
    func open(file: String, origin: Origin = .own) throws -> EditorDocument {
        let key = Self.key(file, origin)
        if let d = documents[key] { return d }
        guard let ws = workspace(for: origin) else { throw EditorError.noFile(file) }
        let url = ws.url(forRelative: file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw EditorError.noFile(file) }
        let doc = EditorDocument(file: file, origin: origin, url: url, text: text,
                                 isReadOnly: isReadOnly(file: file, origin: origin), groupsUndoByEvent: undoGroupsByEvent)
        doc.onEdit = { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.edited(doc)
        }
        documents[key] = doc
        return doc
    }

    /// Makes `file` the shown buffer, optionally moving to a span.
    func show(file: String, origin: Origin = .own, span: SourceTarget.Span? = nil) throws {
        let doc = try open(file: file, origin: origin)
        current = doc
        if let span {
            revealSerial += 1
            reveal = Reveal(serial: revealSerial, file: file, origin: origin, line: span.line, col: span.col,
                            endLine: span.endLine, endCol: span.endCol)
        }
        if !doc.isChecked { scheduleCheck(after: .zero) }
    }

    /// The `.synod` files next to `doc`, for the file picker.
    func siblingFiles(of doc: EditorDocument) -> [String] {
        let dir = Self.folder(of: doc.file)
        let url = workspace(for: doc.origin)?.url(forRelative: dir)
        let names = (url.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? [])
            .filter { $0.hasSuffix(".synod") }.sorted()
        var files = names.map { dir == "." ? $0 : dir + "/" + $0 }
        if !files.contains(doc.file) { files.append(doc.file) }
        return files
    }

    var dirtyDocuments: [EditorDocument] { documents.values.filter(\.isDirty).sorted { $0.file < $1.file } }

    // MARK: Checks

    private func edited(_ doc: EditorDocument) {
        scheduleCheck(after: debounce)
    }

    /// The shown program or its set of packages changed: its report is no longer valid.
    func programChanged() {
        programReport = nil
        programReportTarget = nil
        scheduleCheck(after: .zero)
    }

    func scheduleCheck(after delay: Duration) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            await self?.runCheck()
        }
    }

    /// Checks now, replacing any check that is scheduled or in flight (headless runs and tests).
    func checkNow() async {
        checkTask?.cancel()
        await runCheck()
    }

    /// Checks the unsaved buffers (an overlay) and the saved files of the shown program, then
    /// gives each open buffer its tokens and diagnostics. A result is applied to a buffer only
    /// when its text has not changed since the snapshot (decision 81).
    func runCheck() async {
        guard let doc = current, let runner = runner(), let ws = workspace(for: doc.origin) else { return }
        let origin = doc.origin
        generation += 1
        let gen = generation
        let checker = OverlayChecker(workspace: ws, runner: runner, cache: cache)
        let open = documents.values.filter { $0.origin == origin }
        let versions = Dictionary(open.map { ($0.file, $0.version) }, uniquingKeysWith: { a, _ in a })
        var buffers: [String: String] = [:]
        for d in open where d.isDirty && !d.isReadOnly { buffers[d.file] = d.text }
        var targets: [String] = []
        let program = programTarget().flatMap { $0.origin == origin ? $0.relPath : nil }
        if let program { targets.append(program) }
        if !doc.file.hasPrefix("vendor/") {
            let folder = Self.folder(of: doc.file)
            if !targets.contains(folder) { targets.append(folder) }
        }
        isChecking = true
        defer { if gen == generation { isChecking = false } }
        for target in targets {
            let report: CheckReport
            do {
                report = try await checker.check(target: target, buffers: buffers)
            } catch is CancellationError {
                return
            } catch {
                if gen == generation { lastError = error.localizedDescription }
                return
            }
            guard gen == generation, !Task.isCancelled else { return }
            lastError = nil
            applyReport(report, origin: origin, versions: versions)
            if target == program, origin == .own {
                programReport = report
                programReportTarget = target
            }
            if report.tokens(for: doc.file) != nil || doc.file.hasPrefix("vendor/") {
                didCheck?(doc, report)
                break
            }
        }
        checkCount += 1
    }

    private func applyReport(_ report: CheckReport, origin: Origin, versions: [String: Int]) {
        for doc in documents.values where doc.origin == origin {
            guard let v = versions[doc.file] else { continue }
            let ft = report.files.first { $0.file == doc.file || CheckReport.workspacePath(ofDefinitionFile: $0.file) == doc.file }
            let hasDiagnostics = report.diagnostics.contains { d in d.file == doc.file || d.labels.contains { $0.file == doc.file } }
            guard ft != nil || hasDiagnostics else { continue }
            doc.setCheck(tokens: ft, diagnostics: report.diagnostics, forVersion: v)
        }
    }

    // MARK: Saving

    /// Writes the buffer atomically, then runs `synod fmt` on the file (decision 81). When fmt
    /// changes the file, the buffer takes the formatted text as one undoable "Format" change with
    /// the selection kept by line and column. When fmt refuses, the file stays as written.
    /// The file watcher starts the run.
    @discardableResult
    func save(file: String, origin: Origin = .own) async throws -> SaveResult {
        let doc = try open(file: file, origin: origin)
        guard !doc.isReadOnly else { throw EditorError.readOnly(file) }
        let key = doc.id
        saving.insert(key)
        defer { saving.remove(key) }
        let text = doc.text
        let version = doc.version
        if text != doc.savedText || (try? String(contentsOf: doc.url, encoding: .utf8)) != text {
            try Data(text.utf8).write(to: doc.url, options: .atomic)
        }
        doc.markSaved(text)
        doc.formatOutput = nil
        doc.conflict = nil
        var result = SaveResult.saved(formatted: false)
        if let runner = runner(), let ws = workspace(for: origin) {
            doc.status = "Formatting…"
            do {
                switch try await SynodCore.Formatter(workspace: ws, runner: runner).format(relativePath: file) {
                case .formatted(let changed):
                    if changed, let disk = try? String(contentsOf: doc.url, encoding: .utf8) {
                        if doc.version == version {
                            let pos = doc.linePosition(ofOffset: doc.selection.location)
                            doc.replaceText(with: disk, actionName: "Format")
                            if let pos, let off = doc.positions.utf16Offset(line: pos.line, col: pos.col) {
                                doc.requestSelection(NSRange(location: off, length: 0))
                            }
                        }
                        doc.markSaved(disk)
                    }
                    result = .saved(formatted: changed)
                    doc.status = changed ? "Saved and formatted" : "Saved"
                case .refused(let output):
                    doc.formatOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = .formatRefused(output: doc.formatOutput ?? "")
                    doc.status = "Saved; not formatted"
                }
            } catch {
                doc.status = "Saved; fmt failed: \(error.localizedDescription)"
                throw error
            }
        } else {
            doc.status = "Saved"
        }
        didSave?(doc)
        scheduleCheck(after: .zero)
        return result
    }

    /// ⌘S: saves the shown buffer, reporting problems in `lastError`.
    func saveCurrent() {
        guard let doc = current, !doc.isReadOnly, !userLocked else { return }
        Task { [weak self] in
            do { try await self?.save(file: doc.file, origin: doc.origin) } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Programmatic edits (Break it)

    /// Changes a buffer's text with `transform` as one undoable change. The file is not written;
    /// call `save(file:)` for that.
    func applyEdit(file: String, origin: Origin = .own, actionName: String = "Edit",
                   transform: (String) throws -> String) async throws {
        let doc = try open(file: file, origin: origin)
        guard !doc.isReadOnly else { throw EditorError.readOnly(file) }
        let new = try transform(doc.text)
        doc.replaceText(with: new, actionName: actionName)
    }

    // MARK: Claude's edits (the editor MCP server, decision 99)

    /// Whether `file` may be written by a tool: a `.synod` file or `synod.mod` outside `vendor/`, `out/` and
    /// dot or underscore folders.
    static func isWritablePath(_ file: String) -> Bool {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !parts.contains(where: \.isEmpty) else { return false }
        for dir in parts.dropLast() where dir == "vendor" || dir == "out" || dir.hasPrefix(".") || dir.hasPrefix("_") { return false }
        if name.hasPrefix(".") || name.hasPrefix("_") { return false }
        return name.hasSuffix(".synod") || (parts.count == 1 && name == "synod.mod")
    }

    /// Throws `read-only` when a tool may not change `file`.
    func requireWritable(_ file: String) throws {
        if ownReadOnly { throw EditorToolError(.readOnly, "bundled examples; copy them to a folder first") }
        if file.hasPrefix("vendor/") { throw EditorToolError(.readOnly, "\(file) is vendored code") }
        if !Self.isWritablePath(file) { throw EditorToolError(.readOnly, "\(file) is not a writable Synod file") }
    }

    /// Opens a buffer for a tool; a file that does not exist is `not-found`.
    func openForTools(_ file: String) throws -> EditorDocument {
        do { return try open(file: file) } catch { throw EditorToolError(.notFound, "\(file) does not exist or is not text") }
    }

    /// Applies non-overlapping edits (1-based lines, code-point columns, ends exclusive) to one buffer
    /// as one undo group named "Claude Edit". `version` must be the buffer's current one.
    @discardableResult
    func applyEdits(path file: String, version: Int, edits: [EditorTextEdit], actionName: String = "Claude Edit") throws -> Int {
        try requireWritable(file)
        let doc = try openForTools(file)
        guard doc.version == version else {
            throw EditorToolError(.versionMismatch, "buffer is at version \(doc.version); read it again")
        }
        let positions = doc.positions
        var resolved: [TextEdit] = []
        for (i, e) in edits.enumerated() {
            guard let a = positions.utf16Offset(line: e.line, col: e.col), let b = positions.utf16Offset(line: e.endLine, col: e.endCol), b >= a else {
                throw EditorToolError(.badRange, "edit \(i + 1) is outside the text or ends before it starts")
            }
            resolved.append(TextEdit(range: NSRange(location: a, length: b - a), replacement: e.text))
        }
        let ascending = resolved.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length < $1.range.length
        }
        for (a, b) in zip(ascending, ascending.dropFirst()) {
            if NSMaxRange(a.range) > b.range.location || (a.range.location == b.range.location && a.range.length == 0 && b.range.length == 0) {
                throw EditorToolError(.badRange, "edits overlap")
            }
        }
        let removed = ascending.reduce(0) { $0 + $1.range.length }
        let added = ascending.reduce(0) { $0 + $1.replacementLength }
        if positions.utf16Length - removed + added > 1_048_576 { throw EditorToolError(.tooLarge, "the buffer would be larger than 1 MB") }
        doc.apply(Array(ascending.reversed()), actionName: actionName)
        return doc.version
    }

    /// Replaces a buffer's whole text as one undo group named "Claude Edit". `version` must be current.
    @discardableResult
    func replaceBuffer(path file: String, version: Int, text: String, actionName: String = "Claude Edit") throws -> Int {
        try requireWritable(file)
        let doc = try openForTools(file)
        guard doc.version == version else {
            throw EditorToolError(.versionMismatch, "buffer is at version \(doc.version); read it again")
        }
        doc.replaceText(with: text, actionName: actionName)
        return doc.version
    }

    /// Creates a new file on disk (atomic write, missing folders created), runs `synod fmt` on it and opens it.
    func createFile(path file: String, text: String) async throws -> (version: Int, formatted: Bool) {
        try requireWritable(file)
        guard file.hasSuffix(".synod") else { throw EditorToolError(.badArguments, "create_file makes .synod files only") }
        let url = workspace.url(forRelative: file)
        if FileManager.default.fileExists(atPath: url.path) || documents[Self.key(file, .own)] != nil {
            throw EditorToolError(.exists, "\(file) already exists")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw EditorToolError(.badArguments, "cannot write \(file): \(error.localizedDescription)")
        }
        var formatted = false
        if let runner = runner(),
           case .formatted(let changed)? = try? await SynodCore.Formatter(workspace: workspace, runner: runner).format(relativePath: file) {
            formatted = changed
        }
        try show(file: file)
        return (documents[Self.key(file, .own)]?.version ?? 0, formatted)
    }

    /// Checks the whole module including the unsaved buffers. When the check takes longer than `timeout`
    /// the previous report comes back with `stale` true.
    func checkModule(timeout: Duration = .seconds(5)) async throws -> (report: CheckReport?, stale: Bool) {
        guard let runner = runner() else { throw EditorError.noCompiler }
        let checker = OverlayChecker(workspace: workspace, runner: runner, cache: cache)
        var buffers: [String: String] = [:]
        for d in documents.values where d.origin == .own && d.isDirty && !d.isReadOnly { buffers[d.file] = d.text }
        let given = buffers
        let fresh: CheckReport? = try await withThrowingTaskGroup(of: CheckReport?.self) { group in
            group.addTask { try await checker.check(target: ".", buffers: given) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let fresh {
            moduleReport = fresh
            return (fresh, false)
        }
        return (moduleReport, true)
    }

    /// Forgets a buffer (the file was removed by a revert).
    func closeDocument(file: String, origin: Origin = .own) {
        guard let doc = documents.removeValue(forKey: Self.key(file, origin)) else { return }
        doc.onEdit = nil
        if current === doc { current = nil }
    }

    /// Takes the disk text into every open buffer of the workspace, dropping unsaved edits and undo history;
    /// buffers whose file is gone are closed (Revert).
    func discardEditsAndReload() {
        for doc in Array(documents.values) where doc.origin == .own {
            if let disk = try? String(contentsOf: doc.url, encoding: .utf8) {
                doc.reload(from: disk)
            } else {
                closeDocument(file: doc.file, origin: .own)
            }
        }
        scheduleCheck(after: .zero)
    }

    // MARK: Line highlight (Break it)

    /// Marks `line` of a file in red and shows it (the rule a Break it broke).
    func highlight(line: Int, inFile file: String, origin: Origin) {
        clearHighlight()
        guard let doc = try? open(file: file, origin: origin) else { return }
        doc.setLineHighlight(line)
        highlighted = doc
    }

    func clearHighlight() {
        highlighted?.setLineHighlight(nil)
        highlighted = nil
    }

    // MARK: Quick fixes

    func canApply(_ fix: EditorFix) -> Bool {
        guard !isReadOnly(file: fix.file, origin: fix.origin) else { return false }
        if let doc = documents[Self.key(fix.file, fix.origin)] { return doc.isChecked }
        return true
    }

    /// Applies a help's edits to its own file's buffer, in descending position order, as one
    /// undoable change (decision 81). Only the user's pick calls this.
    func apply(_ fix: EditorFix) throws {
        guard !isReadOnly(file: fix.file, origin: fix.origin) else { throw EditorError.readOnly(fix.file) }
        let wasOpen = documents[Self.key(fix.file, fix.origin)] != nil
        let doc = try open(file: fix.file, origin: fix.origin)
        if wasOpen && !doc.isChecked { throw EditorError.stale }
        guard let edits = TextEdit.edits(from: fix.help, in: doc.positions) else { throw EditorError.stale }
        doc.apply(edits, actionName: "Quick Fix")
    }

    /// ⌘.: the fixes at the caret of the shown buffer; one is applied after the user picks it from
    /// the view's menu.
    func quickFix() {
        guard let doc = current else { return }
        let fixes = doc.fixes(atOffset: doc.selection.location)
        presentFixes?(fixes)
    }

    // MARK: Go to definition

    func definition(in doc: EditorDocument, atOffset offset: Int) -> Definition? {
        guard let def = doc.token(atOffset: offset)?.def else { return nil }
        return Definition(file: CheckReport.workspacePath(ofDefinitionFile: def.file), origin: doc.origin,
                          line: def.line, col: def.col)
    }

    /// Opens the declaration of the word at `offset` (⌘-click, ⌘↓). False when the word has none.
    @discardableResult
    func goToDefinition(in doc: EditorDocument, atOffset offset: Int) throws -> Bool {
        guard let d = definition(in: doc, atOffset: offset) else { return false }
        try show(file: d.file, origin: d.origin, span: SourceTarget.Span(line: d.line, col: d.col))
        return true
    }

    func goToDefinitionAtCaret() {
        guard let doc = current else { return }
        do {
            if try !goToDefinition(in: doc, atOffset: doc.selection.location) { NSSound.beep() }
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Outside changes

    /// Called when files in the workspace changed on disk: clean buffers reload, dirty ones keep
    /// their text and show a conflict banner.
    func diskChanged() {
        for doc in documents.values where !saving.contains(doc.id) {
            guard let disk = try? String(contentsOf: doc.url, encoding: .utf8), disk != doc.savedText else { continue }
            if doc.isDirty {
                if disk != doc.text { doc.conflict = disk } else { doc.markSaved(disk) }
            } else {
                doc.reload(from: disk)
            }
        }
        if !documents.isEmpty { scheduleCheck(after: .milliseconds(100)) }
    }

    func reloadFromDisk(_ doc: EditorDocument) {
        guard let disk = doc.conflict ?? (try? String(contentsOf: doc.url, encoding: .utf8)) else { return }
        doc.reload(from: disk)
        scheduleCheck(after: .zero)
    }

    /// "Keep mine": the buffer stays and now counts as edited against the new disk text.
    func keepMine(_ doc: EditorDocument) {
        if let disk = doc.conflict { doc.markSaved(disk) }
        doc.conflict = nil
    }
}
