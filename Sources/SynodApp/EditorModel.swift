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

    /// Quiet time after the last keystroke before unsaved buffers are checked (decision 81).
    var debounce: Duration = .milliseconds(300)
    /// False in headless runs, which have no run-loop events to close undo groups.
    @ObservationIgnored var undoGroupsByEvent = true

    private(set) var documents: [String: EditorDocument] = [:]
    private(set) var current: EditorDocument?
    /// The latest check of the shown program, including unsaved buffers; the Problems list prefers it.
    private(set) var programReport: CheckReport?
    private(set) var programReportTarget: String?
    private(set) var reveal: Reveal?
    private(set) var isChecking = false
    /// Counts finished checks (headless runs and tests wait on it).
    private(set) var checkCount = 0
    var lastError: String?

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revealSerial = 0
    @ObservationIgnored private var saving: Set<String> = []

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
            if report.tokens(for: doc.file) != nil || doc.file.hasPrefix("vendor/") { break }
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
        guard let doc = current, !doc.isReadOnly else { return }
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
