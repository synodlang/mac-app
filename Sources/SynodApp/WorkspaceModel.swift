import AppKit
import Foundation
import Observation
import SwiftUI
import SynodCore
import SynodWeb

enum SpeedChoice {
    static let all: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    static func label(_ r: Double) -> String { r == r.rounded() ? "\(Int(r))×" : "\(r)×" }
}

/// Where the editor should look: a file, and optionally a span to reveal.
struct SourceTarget: Equatable {
    struct Span: Equatable {
        var line: Int
        var col: Int
        var endLine: Int?
        var endCol: Int?
    }
    var file: String          // module-relative
    var origin: WorkspaceModel.Origin
    var primary: Span?
    var secondary: [Span] = []
}

@MainActor @Observable
final class WorkspaceModel {
    enum Origin: String, Hashable { case own, examples }

    struct Item: Hashable, Identifiable {
        enum Kind: String, Hashable { case program, package }
        var origin: Origin
        var kind: Kind
        var relPath: String
        var id: String { "\(origin.rawValue):\(kind.rawValue):\(relPath)" }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case inspector = "Inspector", problems = "Problems"
        var id: String { rawValue }
    }

    let workspace: Workspace
    let examples: Workspace?
    let isReadOnly: Bool
    let env: AppEnvironment
    let coordinator = RunCoordinator()
    let editor: EditorModel
    /// Phrase completion of the editor (decision 92).
    let completion: CompletionController
    /// The prompt bar (decision 96).
    let claude = ClaudeModel()

    private(set) var scan: Workspace.Scan
    private(set) var examplesScan: Workspace.Scan?
    var selection: Item?
    private(set) var stage: StageController?
    private(set) var stageError: String?

    var mode: RunOptions.Mode = .ordered
    var seedText = ""
    var speed: Double = 1
    private(set) var timeline = TimelineModel.empty

    var tab: InspectorTab = .inspector
    var inspectorVisible = true
    /// The node the inspector shows. Clicking a node on the stage, a row in the node list or a
    /// Compare side sets it; the stage outlines it once the user chose it.
    var selectedNode: String? {
        didSet { if oldValue != selectedNode { selectionChanged() } }
    }
    /// The node outlined on the stage (the user's pick, not the inspector's default).
    private(set) var outlinedNode: String?
    /// A message dot the user clicked (its trace message id), for Break it's "Drop this message".
    var selectedMessage: Int?
    /// The nodes inside the box the user dragged on the stage (the Partition side).
    var boxNodes: [String] = []
    var onlySelectedNode = false
    var source: SourceTarget?
    var editorVisible = true

    var caption: String?
    var banner: String?
    var predictEnabled = false
    var predictQuestion: String?
    /// The choices of the question (empty: the viewer types an answer).
    var predictChoices: [String] = []
    var predictAnswer = ""
    /// The choice saved the last time this question was answered.
    var predictPreviousChoice: Int?
    var showExport = false
    /// Break it (decisions 85 and 86).
    @ObservationIgnored let breakIt = BreakItModel()
    /// Compare (decision 87); nil outside it.
    var compare: CompareModel?
    var compareBusy = false
    var compareError: String?
    /// Counts the runs put on the stage (caches keyed by run).
    private(set) var runSerial = 0
    @ObservationIgnored private var autoSelecting = false

    /// True once the window closed: editor tool calls for it are refused.
    private(set) var isStopped = false

    private var fileRunsHeldUntil: ContinuousClock.Instant?
    private var watcher: FileWatcher?
    private var eventTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    private var predict = PredictLogic()
    private var scrub = Throttle(perSecond: 60)

    init(workspace: Workspace, env: AppEnvironment = .shared, recordRecent: Bool = true) {
        self.workspace = workspace
        self.env = env
        scan = workspace.scan()
        let exURL = env.examplesURL
        let exWorkspace = exURL.flatMap { try? Workspace.open($0) }
        isReadOnly = exWorkspace.map { Self.isInside(workspace.root, $0.root) } ?? false
        examples = isReadOnly ? nil : exWorkspace
        examplesScan = examples?.scan()
        editor = EditorModel(workspace: workspace, examples: examples, ownReadOnly: isReadOnly,
                             runner: { [env] in env.runner })
        completion = CompletionController(editor: editor, isEnabled: { [env] in env.completionEnabled })

        do {
            let s = try StageController(assets: WebAssets.locate())
            stage = s
        } catch {
            stageError = "The player could not start: \(error.localizedDescription)"
        }
        editor.programTarget = { [weak self] in
            guard let self, let s = self.selection, s.kind == .program else { return nil }
            return (s.origin, s.relPath)
        }
        coordinator.currentSeq = { [weak self] in self?.currentFact?.seq }
        coordinator.apply = { [weak self] run, seek, keepTime in
            try await self?.applyToStage(run, seek: seek, keepTime: keepTime)
        }
        breakIt.host = self
        editor.completion = completion
        editor.didCheck = { [weak completion] doc, report in completion?.checked(doc, report: report) }
        claude.host = self
        claude.config = { [weak self] in self?.claudeConfig() }
        claude.isEnabled = { [env] in env.promptBarEnabled }
        WorkspaceRegistry.add(self)
        startEventLoop()
        startWatching()
        if recordRecent { env.addRecent(workspace.root) }
        if let first = scan.programs.first(where: { $0.name == "tcp" }) ?? scan.programs.first {
            select(Item(origin: .own, kind: .program, relPath: first.relPath))
        } else if let first = examplesScan?.programs.first, scan.packages.isEmpty {
            select(Item(origin: .examples, kind: .program, relPath: first.relPath))
        }
    }

    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p + "/")
    }

    func stop() {
        isStopped = true
        WorkspaceRegistry.remove(self)
        claude.shutdown()
        completion.stop()
        exitCompare()
        eventTask?.cancel()
        watchTask?.cancel()
        captionTask?.cancel()
        watcher?.stop()
        editor.stop()
        coordinator.cancel()
        stage?.tearDown()
        stage = nil
    }

    // MARK: Selection and running

    func workspace(for origin: Origin) -> Workspace? { origin == .own ? workspace : examples }

    var activeWorkspace: Workspace? { selection.flatMap { workspace(for: $0.origin) } }

    var activeProgram: Workspace.Program? {
        guard let s = selection, s.kind == .program, let ws = workspace(for: s.origin) else { return nil }
        let programs = (s.origin == .own ? scan : examplesScan ?? scan).programs
        _ = ws
        return programs.first { $0.relPath == s.relPath }
    }

    var programKey: String? {
        guard let ws = activeWorkspace, let p = activeProgram else { return nil }
        return ws.root.path + "|" + p.relPath
    }

    /// Refreshes the program and package lists (after Claude changed files).
    func rescan() {
        scan = workspace.scan()
        examplesScan = examples?.scan()
    }

    /// What a prompt-bar request needs, from Settings; nil when something is missing.
    func claudeConfig() -> ClaudeModel.Config? {
        guard env.promptBarProblem == nil, let claude = env.claudeURL, let skills = env.skillsURL,
              let synod = env.tools?.synod, let bridge = HelperTools.editorBridge() else { return nil }
        let model = env.claudeModel.trimmingCharacters(in: .whitespaces)
        return ClaudeModel.Config(claude: claude, model: model.isEmpty ? nil : model, skills: skills, synod: synod, bridge: bridge)
    }

    func select(_ item: Item, run runIt: Bool = true) {
        exitCompare()
        breakIt.reset()
        selectedMessage = nil
        boxNodes = []
        selection = item
        guard let ws = workspace(for: item.origin) else { return }
        switch item.kind {
        case .program:
            if let p = activeProgram {
                source = SourceTarget(file: relFile(p.relPath, p.mainFile), origin: item.origin)
                try? editor.show(file: relFile(p.relPath, p.mainFile), origin: item.origin)
                editor.programChanged()
                if runIt { run(.selection) }
            }
        case .package:
            let list = (item.origin == .own ? scan : examplesScan ?? scan).packages
            if let pkg = list.first(where: { $0.relPath == item.relPath }), let f = pkg.files.first {
                source = SourceTarget(file: relFile(pkg.relPath, f), origin: item.origin)
                try? editor.show(file: relFile(pkg.relPath, f), origin: item.origin)
                editorVisible = true
            }
        }
        _ = ws
    }

    private func relFile(_ dir: String, _ file: String) -> String { dir == "." ? file : dir + "/" + file }

    var runOptions: RunOptions {
        let trimmed = seedText.trimmingCharacters(in: .whitespaces)
        return RunOptions(mode: mode, seed: UInt64(trimmed))
    }

    var seedIsValid: Bool {
        let t = seedText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || UInt64(t) != nil
    }

    func run(_ trigger: RunCoordinator.Trigger, preserveTime: Bool = false) {
        guard let ws = activeWorkspace, let program = activeProgram, let key = programKey else { return }
        guard let runner = env.runner else {
            stageError = "The synod compiler was not found. Set its path in Settings."
            return
        }
        guard seedIsValid else { return }
        let pipeline = RunPipeline(workspace: ws, runner: runner)
        coordinator.trigger(trigger, request: .init(program: program, programKey: key, options: runOptions, runner: pipeline,
                                                    preserveTime: preserveTime))
    }

    private func applyToStage(_ run: LoadedRun, seek: Double?, keepTime: Bool) async throws {
        guard let stage else { throw HeadlessError.noStage }
        try await stage.setScene(run.sceneText, keepTime: keepTime)
        if let seek { try await stage.seek(to: seek) }
        try? await stage.setRate(speed)
        try? await stage.setStopAtPause(predictEnabled)
        timeline = TimelineModel(scene: run.scene)
        runSerial += 1
        if selectedNode == nil || !run.trace.nodes.contains(selectedNode ?? "") {
            autoSelecting = true
            selectedNode = run.trace.nodes.first
            autoSelecting = false
        }
        if let n = outlinedNode, !run.trace.nodes.contains(n) { outlinedNode = nil }
        try? await stage.setSelection(outlinedNode)
        banner = nil
        if !keepTime { caption = nil }
    }

    enum HeadlessError: Error, LocalizedError {
        case noStage
        var errorDescription: String? { "The player is not available." }
    }

    var loaded: LoadedRun? { coordinator.loaded }

    /// The fact the stage is at, from the trace map (the same lookup as the player).
    var currentFact: SceneSummary.TraceEntry? {
        guard let stage, let run = loaded else { return nil }
        return run.trace.factAt(stage.state.time)
    }

    // MARK: Player controls

    func togglePlay() {
        guard let stage else { return }
        Task {
            if stage.state.playing { try? await stage.pause() } else {
                predictQuestion = nil
                predictChoices = []
                // Re-assert in the same task as play so no earlier toggle can be lost or reordered.
                try? await stage.setStopAtPause(predictEnabled)
                try? await stage.play()
            }
        }
    }

    func stepFact(_ delta: Int) {
        guard let stage else { return }
        Task { _ = delta > 0 ? try? await stage.nextFact() : try? await stage.prevFact() }
    }

    func scrub(toFraction f: Double, force: Bool = false) {
        guard let stage else { return }
        guard force || scrub.allows(at: ProcessInfo.processInfo.systemUptime) else { return }
        let at = timeline.time(atFraction: f)
        Task { try? await stage.seek(to: at) }
    }

    func seek(to at: Double) {
        guard let stage else { return }
        Task { try? await stage.seek(to: at) }
    }

    func setSpeed(_ r: Double) {
        speed = r
        guard let stage else { return }
        Task { try? await stage.setRate(r) }
    }

    func setMode(_ m: RunOptions.Mode) {
        guard m != mode else { return }
        mode = m
        run(.mode)
    }

    func jump(toSeq seq: Int) {
        guard let stage, let run = loaded, let at = run.trace.timeOfSeq(seq) else { return }
        Task {
            try? await stage.pause()
            try? await stage.seek(to: at)
        }
    }

    // MARK: Predict

    func setPredict(_ on: Bool) {
        predictEnabled = on
        if !on { predictQuestion = nil; predictChoices = [] }
        guard let stage else { return }
        Task { try? await stage.setStopAtPause(on) }
    }

    /// Text mode (a question without choices): saves the typed answer and plays on.
    func continuePredict() {
        savePredict(answer: predictAnswer, choice: nil)
        resumeAfterPredict()
    }

    /// Choice mode: saves the pick (its index and the list, `answer` is the chosen text) and plays on.
    /// Nothing is graded; the run shows what happens.
    func choosePredict(_ index: Int) {
        guard predictChoices.indices.contains(index) else { return }
        savePredict(answer: predictChoices[index], choice: index)
        resumeAfterPredict()
    }

    private func savePredict(answer: String, choice: Int?) {
        guard let q = predictQuestion, let ws = activeWorkspace, let p = activeProgram else { return }
        let store = AnswerStore(moduleRoot: ws.root, program: p.relPath)
        let entry = AnswerStore.Entry(question: q, answer: answer, seed: loaded?.options.seed, mode: mode.rawValue,
                                      choice: choice, choices: choice == nil ? nil : predictChoices)
        try? store.save(entry)
    }

    private func resumeAfterPredict() {
        predictQuestion = nil
        predictChoices = []
        predictAnswer = ""
        predictPreviousChoice = nil
        guard let stage else { return }
        Task {
            try? await stage.setStopAtPause(predictEnabled)
            try? await stage.play()
        }
    }

    // MARK: Events

    private func startEventLoop() {
        guard let stage else { return }
        eventTask = Task { [weak self] in
            for await ev in stage.events {
                self?.handle(ev)
            }
        }
    }

    private func handle(_ ev: PlayerEvent) {
        if compare == nil, let q = predict.handle(ev, predictEnabled: predictEnabled) {
            let saved = AnswerStore(moduleRoot: workspace.root, program: activeProgram?.relPath ?? ".").entry(for: q.text)
            predictQuestion = q.text
            predictChoices = q.choices
            predictAnswer = q.choices.isEmpty ? (saved?.answer ?? "") : ""
            predictPreviousChoice = q.choices.isEmpty ? nil : saved?.choice.flatMap { q.choices.indices.contains($0) ? $0 : nil }
        }
        switch ev {
        case .click(_, _, let hit):
            stageClicked(hit)
        case .box(let rect, _):
            stageBox(rect)
        case .marker(let kind, _, let text, _):
            switch kind {
            case "caption":
                caption = text
                captionTask?.cancel()
                captionTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { self?.caption = nil }
                }
            case "broken", "failed":
                banner = text.isEmpty ? kind.capitalized : text
            default: break
            }
        case .error(let m):
            stageError = m
        default: break
        }
    }

    /// Presentation times of the rules the last Break it broke (the timeline pulses there).
    var pulseTimes: [Double] { breakIt.broken.compactMap { loaded?.trace.timeOfSeq($0.seq) } }

    // MARK: Stage selection (decision 84)

    private func selectionChanged() {
        if !autoSelecting { outlinedNode = selectedNode }
        let node = outlinedNode
        if let compare {
            Task { try? await compare.controller.setSelection(node) }
        } else if let stage {
            Task { try? await stage.setSelection(node) }
        }
    }

    /// A click on the stage: a message dot jumps to its `net.Sent` fact, a node selects it in the
    /// inspector, and empty space clears the message and box selection.
    func stageClicked(_ hit: StageHit?) {
        boxNodes = []
        guard let hit else { selectedMessage = nil; return }
        if let id = hit.msg {
            selectedMessage = id
            tab = .inspector
            inspectorVisible = true
            if let seq = sendSeq(ofMessage: id) { jump(toSeq: seq) }
        } else if let node = hit.node {
            selectedMessage = nil
            selectedNode = node
            outlinedNode = node
            tab = .inspector
            inspectorVisible = true
            if let stage { Task { try? await stage.setSelection(node) } }
        }
    }

    /// A dragged box: the nodes whose box center lies inside it are the Partition side.
    func stageBox(_ rect: StageRect) {
        guard let stage else { return }
        Task {
            let boxes = (try? await stage.nodeBounds()) ?? []
            let inside = BreakItSelection.nodes(inBox: rect, boxes: boxes)
            boxNodes = inside
            selectedMessage = nil
            if !inside.isEmpty { tab = .inspector; inspectorVisible = true }
        }
    }

    /// The seq of the `net.Sent` of message `id` in the shown run.
    func sendSeq(ofMessage id: Int) -> Int? {
        guard let run = loaded else { return nil }
        for e in run.trace.events {
            if case .sent(let env) = e.payload, env.msg.id == id { return e.seq }
        }
        return nil
    }

    // MARK: Watching

    private func startWatching() {
        guard !isReadOnly else { return }
        let w = FileWatcher(root: workspace.root)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.events {
                guard let self else { return }
                self.scan = self.workspace.scan()
                self.editor.diskChanged()
                if self.selection?.origin == .own, !self.fileRunsAreHeld { self.run(.fileChange) }
            }
        }
    }

    /// Break it saves and runs the program itself; the run its own save would start is not needed.
    func holdFileRuns(for d: Duration) { fileRunsHeldUntil = .now + d }

    private var fileRunsAreHeld: Bool { fileRunsHeldUntil.map { ContinuousClock.now < $0 } ?? false }

    // MARK: Sources and problems

    /// Opens a file in the editor, revealing the target's primary span.
    func show(source target: SourceTarget) {
        source = target
        editorVisible = true
        do {
            try editor.show(file: target.file, origin: target.origin, span: target.primary)
        } catch {
            editor.lastError = error.localizedDescription
        }
    }

    /// Problems for the Problems list: the editor's latest check of the shown program (it
    /// includes unsaved buffers), else the last run's.
    var problemReport: CheckReport? {
        if let r = editor.programReport,
           let s = selection, s.kind == .program, editor.programReportTarget == s.relPath { return r }
        return coordinator.diagnostics
    }

    // MARK: Examples

    func copyExamples() {
        guard let src = env.examplesURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose a folder for a copy of the Synod examples."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = Self.freeName(dir.appendingPathComponent("synod-examples"))
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            copiedTo = dest
        } catch {
            stageError = "Could not copy the examples: \(error.localizedDescription)"
        }
    }

    var copiedTo: URL?

    static func freeName(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-\(n)")
            n += 1
        }
        return candidate
    }
}
