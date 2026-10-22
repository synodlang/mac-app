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

/// Where the read-only source view looks.
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
        case inspector = "Inspector", problems = "Problems", source = "Source"
        var id: String { rawValue }
    }

    let workspace: Workspace
    let examples: Workspace?
    let isReadOnly: Bool
    let env: AppEnvironment
    let coordinator = RunCoordinator()

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
    var selectedNode: String?
    var onlySelectedNode = false
    var source: SourceTarget?

    var caption: String?
    var banner: String?
    var predictEnabled = false
    var predictQuestion: String?
    var predictAnswer = ""
    var showExport = false

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

        do {
            let s = try StageController(assets: WebAssets.locate())
            stage = s
        } catch {
            stageError = "The player could not start: \(error.localizedDescription)"
        }
        coordinator.currentSeq = { [weak self] in self?.currentFact?.seq }
        coordinator.apply = { [weak self] run, seek, keepTime in
            try await self?.applyToStage(run, seek: seek, keepTime: keepTime)
        }
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
        eventTask?.cancel()
        watchTask?.cancel()
        captionTask?.cancel()
        watcher?.stop()
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

    func select(_ item: Item) {
        selection = item
        guard let ws = workspace(for: item.origin) else { return }
        switch item.kind {
        case .program:
            if let p = activeProgram {
                source = SourceTarget(file: relFile(p.relPath, p.mainFile), origin: item.origin)
                run(.selection)
            }
        case .package:
            let list = (item.origin == .own ? scan : examplesScan ?? scan).packages
            if let pkg = list.first(where: { $0.relPath == item.relPath }), let f = pkg.files.first {
                source = SourceTarget(file: relFile(pkg.relPath, f), origin: item.origin)
                tab = .source
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

    func run(_ trigger: RunCoordinator.Trigger) {
        guard let ws = activeWorkspace, let program = activeProgram, let key = programKey else { return }
        guard let runner = env.runner else {
            stageError = "The synod compiler was not found. Set its path in Settings."
            return
        }
        guard seedIsValid else { return }
        let pipeline = RunPipeline(workspace: ws, runner: runner)
        coordinator.trigger(trigger, request: .init(program: program, programKey: key, options: runOptions, runner: pipeline))
    }

    private func applyToStage(_ run: LoadedRun, seek: Double?, keepTime: Bool) async throws {
        guard let stage else { throw HeadlessError.noStage }
        try await stage.setScene(run.sceneText, keepTime: keepTime)
        if let seek { try await stage.seek(to: seek) }
        try? await stage.setRate(speed)
        try? await stage.setStopAtPause(predictEnabled)
        timeline = TimelineModel(scene: run.scene)
        if selectedNode == nil || !run.trace.nodes.contains(selectedNode ?? "") { selectedNode = run.trace.nodes.first }
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
        if !on { predictQuestion = nil }
        guard let stage else { return }
        Task { try? await stage.setStopAtPause(on) }
    }

    func continuePredict() {
        if let q = predictQuestion, let ws = activeWorkspace, let p = activeProgram {
            let store = AnswerStore(moduleRoot: ws.root, program: p.relPath)
            let entry = AnswerStore.Entry(question: q, answer: predictAnswer, seed: loaded?.options.seed,
                                          mode: mode.rawValue)
            try? store.save(entry)
        }
        predictQuestion = nil
        predictAnswer = ""
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
        if let q = predict.handle(ev, predictEnabled: predictEnabled) {
            predictQuestion = q
            predictAnswer = AnswerStore(moduleRoot: workspace.root, program: activeProgram?.relPath ?? ".").entry(for: q)?.answer ?? ""
        }
        switch ev {
        case .marker(let kind, _, let text):
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

    // MARK: Watching

    private func startWatching() {
        guard !isReadOnly else { return }
        let w = FileWatcher(root: workspace.root)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.events {
                guard let self else { return }
                self.scan = self.workspace.scan()
                if self.selection?.origin == .own { self.run(.fileChange) }
            }
        }
    }

    // MARK: Sources and problems

    func fileURL(for target: SourceTarget) -> URL? {
        workspace(for: target.origin)?.url(forRelative: target.file)
    }

    func show(source target: SourceTarget) {
        source = target
        tab = .source
        inspectorVisible = true
    }

    func openInEditor() {
        guard let t = source, let url = fileURL(for: t) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Files of the folder holding the current source file, for the Source picker.
    var siblingFiles: [String] {
        guard let t = source else { return [] }
        let dir = (t.file as NSString).deletingLastPathComponent
        let full = workspace(for: t.origin)?.url(forRelative: dir.isEmpty ? "." : dir)
        let names = (full.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []).filter { $0.hasSuffix(".synod") }.sorted()
        return names.map { dir.isEmpty ? $0 : dir + "/" + $0 }
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
