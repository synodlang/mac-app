import Foundation
import Observation
import SynodCore
import SynodWeb

/// The pure parts of Compare (decision 87): matching nodes by name, comparing a node's fields, and
/// laying markers out on a timeline in simulated time.
enum CompareLogic {
    struct NodePair: Equatable, Identifiable {
        var name: String
        var inLeft: Bool
        var inRight: Bool
        var id: String { name }
        var isMatched: Bool { inLeft && inRight }
    }

    /// Nodes matched by name: the left run's nodes in its order, then those only the right run has.
    static func pairs(left: [String], right: [String]) -> [NodePair] {
        let rs = Set(right)
        let ls = Set(left)
        var out = left.map { NodePair(name: $0, inLeft: true, inRight: rs.contains($0)) }
        out += right.filter { !ls.contains($0) }.map { NodePair(name: $0, inLeft: false, inRight: true) }
        return out
    }

    struct FieldRow: Equatable, Identifiable {
        var name: String
        var left: String?
        var right: String?
        var id: String { name }
        var differs: Bool { left != right }
    }

    /// The fields of a node on both sides, in the left order and then the right-only ones; a field
    /// missing on one side has nil there.
    static func rows(left: NodeState?, right: NodeState?) -> [FieldRow] {
        let l = left?.fields ?? []
        let r = right?.fields ?? []
        let rv = Dictionary(r.map { ($0.name, $0.value.display) }, uniquingKeysWith: { a, _ in a })
        let lv = Dictionary(l.map { ($0.name, $0.value.display) }, uniquingKeysWith: { a, _ in a })
        var rows = l.map { FieldRow(name: $0.name, left: $0.value.display, right: rv[$0.name]) }
        rows += r.filter { lv[$0.name] == nil }.map { FieldRow(name: $0.name, left: nil, right: $0.value.display) }
        return rows
    }

    /// The shared axis: the left run's simulated length (the left side drives the clock).
    static func domain(left: SyncMap, right: SyncMap) -> Double { max(1, Double(left.endTime)) }

    struct Tick: Equatable {
        var x: Double
        var kind: String
        var text: String
        var simMicros: Double
    }

    /// Marker ticks of one run on a track `width` points wide whose axis is `domain` microseconds.
    static func ticks(markers: [SceneSummary.Marker], map: SyncMap, domain: Double, width: Double) -> [Tick] {
        markers.sorted { $0.at < $1.at }.map {
            let t = map.simTime(atPresentation: $0.at)
            return Tick(x: min(max(t / domain, 0), 1) * width, kind: $0.kind, text: $0.text, simMicros: t)
        }
    }
}

enum ComparePreset {
    case nextSeed
    case otherMode
    case program(Workspace.Program)
    case beforeBreakIt
}

/// Two runs side by side on one clock in simulated time (decision 87). The left side drives; the
/// right side follows through the sync maps. Selection is mirrored by node name.
@MainActor @Observable
final class CompareModel {
    struct Side: Equatable {
        var title: String
        var run: LoadedRun
        static func == (a: Side, b: Side) -> Bool { a.title == b.title && a.run.sceneText == b.run.sceneText }
    }

    let controller: CompareController
    private(set) var left: Side
    private(set) var right: Side
    private(set) var leftMap: SyncMap
    private(set) var rightMap: SyncMap
    private(set) var isLoaded = false
    var sync: CompareSync = .sim
    var speed: Double = 1
    var error: String?
    var selectedNode: String? {
        didSet {
            guard oldValue != selectedNode else { return }
            onSelect?(selectedNode)
            let node = selectedNode
            Task { [controller] in try? await controller.setSelection(node) }
        }
    }
    /// Told when the viewer picks a node on either canvas.
    @ObservationIgnored var onSelect: ((String?) -> Void)?

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(controller: CompareController, left: Side, right: Side) {
        self.controller = controller
        self.left = left
        self.right = right
        leftMap = SyncMap(index: left.run.trace, duration: left.run.scene.duration)
        rightMap = SyncMap(index: right.run.trace, duration: right.run.scene.duration)
    }

    static func knots(_ map: SyncMap) -> [SyncKnot] { map.knots.map { SyncKnot(simMicros: Double($0.t), at: $0.at) } }

    /// Loads both scenes into the page and starts listening to it.
    func load() async throws {
        let info = try await controller.setScenes(
            left: left.run.sceneText, right: right.run.sceneText,
            knotsLeft: Self.knots(leftMap), knotsRight: Self.knots(rightMap))
        if let w = (info.warningsLeft + info.warningsRight).first { error = "Player warning: \(w)" }
        isLoaded = true
        try? await controller.setRate(speed)
        startEvents()
    }

    private func startEvents() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, controller] in
            for await ev in controller.events {
                guard let self else { return }
                switch ev {
                case .click(_, _, _, let hit):
                    if let node = hit?.node { self.selectedNode = node }
                case .error(let m): self.error = m
                default: break
                }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        controller.tearDown()
    }

    // MARK: Controls

    var times: CompareTimes { controller.state.times }
    var playing: Bool { controller.state.playing }
    var domain: Double { CompareLogic.domain(left: leftMap, right: rightMap) }
    var pairs: [CompareLogic.NodePair] { CompareLogic.pairs(left: left.run.trace.nodes, right: right.run.trace.nodes) }

    func togglePlay() {
        Task { if playing { try? await controller.pause() } else { try? await controller.play() } }
    }

    func seek(toFraction f: Double) {
        let T = min(max(f, 0), 1) * domain
        Task { try? await controller.seekSim(T) }
    }

    func seek(toSim t: Double) { Task { try? await controller.seekSim(t) } }

    func setSpeed(_ r: Double) {
        speed = r
        Task { try? await controller.setRate(r) }
    }

    func setSync(_ mode: CompareSync) {
        sync = mode
        Task { try? await controller.setSync(mode) }
    }

    func swap() {
        Task {
            if (try? await controller.swap()) != nil {
                let l = self.left, lm = self.leftMap
                self.left = self.right
                self.right = l
                self.leftMap = self.rightMap
                self.rightMap = lm
            }
        }
    }

    func stepFact(_ delta: Int) {
        // The next fact of the left run, by presentation time.
        let entries = left.run.trace.entries
        let at = times.atLeft
        let target: Double?
        if delta > 0 { target = entries.first { $0.at > at + 0.5 }?.at } else { target = entries.last { $0.at < at - 0.5 }?.at }
        if let target { Task { try? await controller.seek(to: target) } }
    }

    // MARK: Inspector data

    func state(of node: String, side: CompareSide) -> NodeState? {
        let run = side == .left ? left.run : right.run
        let at = side == .left ? times.atLeft : times.atRight
        guard let seq = run.trace.factAt(at)?.seq else { return nil }
        return run.trace.state(of: node, atSeq: seq)
    }

    var rows: [CompareLogic.FieldRow] {
        guard let n = selectedNode else { return [] }
        return CompareLogic.rows(left: state(of: n, side: .left), right: state(of: n, side: .right))
    }
}

extension WorkspaceModel {
    var canCompare: Bool { loaded != nil && activeProgram != nil }

    /// Picks the other side, runs it, and shows both (Compare). Predict and Break it are off meanwhile.
    func startCompare(_ preset: ComparePreset) {
        guard !compareBusy, let run = loaded, let program = activeProgram, let ws = activeWorkspace,
              let runner = env.runner else { return }
        compareBusy = true
        compareError = nil
        var leftRun = run
        var rightRun: LoadedRun?
        var otherProgram = program
        var options = RunOptions(mode: run.options.mode, seed: nil)
        switch preset {
        case .nextSeed:
            options = RunOptions(mode: run.options.mode, seed: run.trace.header.seed + 1)
        case .otherMode:
            options = RunOptions(mode: run.options.mode == .ordered ? .proportional : .ordered, seed: run.options.seed)
        case .program(let p):
            otherProgram = p
            options = run.options
        case .beforeBreakIt:
            guard let before = breakIt.before else { compareBusy = false; return }
            leftRun = before
            rightRun = run
        }
        let pipeline = RunPipeline(workspace: ws, runner: runner)
        let key = ws.root.path + "|" + otherProgram.relPath
        let isBefore = rightRun != nil
        let leftProgram = program.relPath
        Task { [weak self] in
            guard let self else { return }
            defer { compareBusy = false }
            do {
                if rightRun == nil {
                    let outcome = try await pipeline.run(program: otherProgram, options: options)
                    guard case .ran(let status, let sceneText, let scene, let trace) = outcome else {
                        throw CompareError("The other run did not finish: \(Self.describe(outcome))")
                    }
                    rightRun = LoadedRun(programKey: key, sceneText: sceneText, scene: scene, trace: trace, status: status, options: options)
                }
                guard let rightRun else { return }
                try? await stage?.pause()
                let controller = try CompareController(assets: WebAssets.locate(), size: CGSize(width: 1200, height: 600))
                let model = CompareModel(
                    controller: controller,
                    left: .init(title: Self.sideTitle(program: leftProgram, run: leftRun) + (isBefore ? " (before)" : ""), run: leftRun),
                    right: .init(title: Self.sideTitle(program: otherProgram.relPath, run: rightRun) + (isBefore ? " (after)" : ""),
                                 run: rightRun))
                model.selectedNode = selectedNode
                model.onSelect = { [weak self] node in
                    guard let self, self.selectedNode != node, let node else { return }
                    self.selectedNode = node
                }
                try await model.load()
                exitCompare()
                compare = model
                predictQuestion = nil
                predictChoices = []
                tab = .inspector
            } catch {
                compareError = error.localizedDescription
            }
        }
    }

    func exitCompare() {
        guard let c = compare else { return }
        c.stop()
        compare = nil
        Task { try? await stage?.setSelection(outlinedNode) }
    }

    static func sideTitle(program: String, run: LoadedRun) -> String {
        let seed = run.options.seed ?? run.trace.header.seed
        return "\(program), seed \(seed), \(run.options.mode.rawValue)"
    }

    static func describe(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .diagnostics(let r): return "\(r.diagnostics.count) diagnostic(s)"
        case .rawProblems(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ran: return "ran"
        }
    }
}

struct CompareError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
