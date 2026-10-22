import Foundation
import Observation
import SynodCore
import SynodWeb

/// Pure helpers for the stage selection.
enum BreakItSelection {
    /// The nodes whose box center lies inside `rect` (the Partition side), in box order.
    static func nodes(inBox rect: StageRect, boxes: [StageNodeBox]) -> [String] {
        boxes.filter { rect.contains(x: $0.rect.x + $0.rect.w / 2, y: $0.rect.y + $0.rect.h / 2) }.map(\.node)
    }
}

/// What Break it needs from the window it works in; `WorkspaceModel` is the real host and tests
/// bring a fake.
@MainActor
protocol BreakItHost: AnyObject {
    var editor: EditorModel { get }
    var loadedRun: LoadedRun? { get }
    /// Counts the runs on the stage; caches are keyed by it.
    var runSerial: Int { get }
    var currentFactSeq: Int? { get }
    /// The shown program's main file; nil when no program is shown.
    var breakItTarget: (file: String, origin: WorkspaceModel.Origin)? { get }
    /// The last check of the shown program had an error.
    var hasCheckErrors: Bool { get }
    var isCompareActive: Bool { get }
    /// Runs the shown program again at the same presentation time, waits for it, and returns the new run.
    func rerunAndWait() async throws -> LoadedRun
    func jump(toSeq seq: Int)
    /// Opens a rule's source line in the editor with a red line highlight.
    func showRule(file: String, line: Int)
    func clearRuleHighlight()
    /// Do not start the run an own save would trigger for a while.
    func holdFileRuns(for d: Duration)
}

/// Break it (decisions 85 and 86): a click becomes one `after T` block at the end of `define main`,
/// edited through the editor's buffer, saved with `synod fmt`, re-run, and checked in the new trace.
@MainActor @Observable
final class BreakItModel {
    /// The sheet: the generated block, its time, and the file it goes into.
    struct Sheet: Equatable {
        var action: BreakItAction
        var plan: BreakItPlan
        var timeText: String
        var file: String
        var error: String?
        /// A drop acts when the message is sent, so its time is fixed.
        var timeIsEditable: Bool {
            if case .dropMessage = action { return false }
            return true
        }
    }

    enum Outcome: Equatable {
        /// The action's fact is in the new trace at `seq`.
        case applied(seq: Int)
        case noEffect
        case failed(String)
    }

    @ObservationIgnored weak var host: BreakItHost?
    var sheet: Sheet?
    private(set) var isWorking = false
    private(set) var outcome: Outcome?
    private(set) var plan: BreakItPlan?
    /// Rules broken by the change and not by the run before it.
    private(set) var broken: [BrokenFact] = []
    /// The good run before the change, for "Compare with before".
    private(set) var before: LoadedRun?
    var canUndo: Bool { snapshot != nil }

    @ObservationIgnored private var snapshot: (file: String, origin: WorkspaceModel.Origin, text: String)?
    @ObservationIgnored private var plannerCache: (run: UUID, planner: BreakItPlanner)?

    // MARK: Offers

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    /// An action is offered only when the last check had no error and the main file is saved.
    var availability: Availability {
        guard let host else { return .unavailable("No workspace") }
        if host.isCompareActive { return .unavailable("Break it is off in Compare.") }
        if isWorking { return .unavailable("Working…") }
        guard host.loadedRun != nil, let t = host.breakItTarget else { return .unavailable("Run a program first.") }
        if host.editor.isReadOnly(file: t.file, origin: t.origin) {
            return .unavailable("Bundled examples are read-only. Copy them to a folder to break them.")
        }
        if host.hasCheckErrors { return .unavailable("Fix the errors first: the last check found one.") }
        if let doc = try? host.editor.open(file: t.file, origin: t.origin), doc.isDirty {
            return .unavailable("Save \(t.file) first.")
        }
        return .available
    }

    var planner: BreakItPlanner? {
        guard let host, let run = host.loadedRun else { return nil }
        if let c = plannerCache, c.run == run.id { return c.planner }
        let p = BreakItPlanner(index: run.trace)
        plannerCache = (run.id, p)
        return p
    }

    func nodeOffer(_ node: String) -> BreakItNodeOffer {
        planner?.offer(forNode: node, factSeq: host?.currentFactSeq) ?? .none
    }

    func messageOffer(_ id: Int) -> BreakItDropOffer { planner?.offer(forMessage: id) ?? .unknown }

    var partitionActive: Bool { planner?.partitionActive(factSeq: host?.currentFactSeq) ?? false }

    // MARK: Sheet

    func begin(_ action: BreakItAction) {
        guard case .available = availability, let host, let planner, let target = host.breakItTarget else { return }
        do {
            let plan = try planner.plan(action, factSeq: host.currentFactSeq)
            sheet = Sheet(action: action, plan: plan, timeText: plan.timeLiteral, file: target.file)
            outcome = nil
        } catch {
            // The reason belongs in the sheet, next to the time that can be corrected.
            sheet = Sheet(action: action, plan: .empty(for: action), timeText: "", file: target.file,
                          error: error.localizedDescription)
            outcome = nil
        }
    }

    /// The user edited the time field: the plan is made again for that time (the node numbers
    /// depend on it). A bad text keeps the last plan and shows the problem.
    func setTimeText(_ text: String) {
        guard var s = sheet, let planner, let host else { return }
        s.timeText = text
        guard s.timeIsEditable else { sheet = s; return }
        guard let us = FormatTime.parse(text.trimmingCharacters(in: .whitespaces)), us >= 0 else {
            s.error = "Write a time like 6001ms or 6s."
            sheet = s
            return
        }
        if let end = planner.endTime, end > 0, us >= end {
            s.error = "The run ends at \(FormatTime.string(microseconds: end)); pick an earlier time."
            sheet = s
            return
        }
        do {
            s.plan = try planner.plan(s.action, at: us, factSeq: host.currentFactSeq)
            s.error = nil
        } catch {
            s.error = error.localizedDescription
        }
        sheet = s
    }

    func cancelSheet() { sheet = nil }

    // MARK: Apply

    /// Edit, save, re-run, check. The edit is one undoable change of the editor buffer.
    func apply() async {
        guard let s = sheet, s.error == nil, let host, let target = host.breakItTarget else { return }
        let plan = s.plan
        sheet = nil
        isWorking = true
        outcome = nil
        broken = []
        host.clearRuleHighlight()
        defer { isWorking = false }
        let previous = host.loadedRun
        do {
            let doc = try host.editor.open(file: target.file, origin: target.origin)
            let original = doc.text
            try await host.editor.applyEdit(file: target.file, origin: target.origin, actionName: "Break it") {
                try MainEditor.apply(plan, to: $0)
            }
            snapshot = (target.file, target.origin, original)
            self.plan = plan
            host.holdFileRuns(for: .seconds(2))
            _ = try await host.editor.save(file: target.file, origin: target.origin)
            let run = try await host.rerunAndWait()
            before = previous
            if let seq = BreakItVerifier.verify(plan, in: run.trace) {
                outcome = .applied(seq: seq)
                host.jump(toSeq: seq)
            } else {
                outcome = .noEffect
            }
            broken = BreakItVerifier.newlyBroken(previous: previous?.trace, current: run.trace)
            if let loc = broken.first?.location { host.showRule(file: loc.file, line: loc.line) }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    /// "Undo Break it": the buffer goes back to the text before the change, is saved and re-run.
    func undo() async {
        guard let snap = snapshot, let host else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let doc = try host.editor.open(file: snap.file, origin: snap.origin)
            // The editor's own undo steps first (Break it, then the format after saving), so ⌘Z history stays sane.
            var steps = 0
            while doc.text != snap.text, doc.undoManager.canUndo, steps < 4 {
                doc.undoManager.undo()
                steps += 1
            }
            if doc.text != snap.text {
                try await host.editor.applyEdit(file: snap.file, origin: snap.origin, actionName: "Undo Break it") { _ in snap.text }
            }
            host.holdFileRuns(for: .seconds(2))
            _ = try await host.editor.save(file: snap.file, origin: snap.origin)
            snapshot = nil
            outcome = nil
            broken = []
            plan = nil
            before = nil
            host.clearRuleHighlight()
            _ = try await host.rerunAndWait()
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    /// Hides the banners (the change stays).
    func dismiss() {
        outcome = nil
        broken = []
        host?.clearRuleHighlight()
    }

    /// Forgets everything: another program was chosen.
    func reset() {
        sheet = nil
        outcome = nil
        broken = []
        plan = nil
        before = nil
        snapshot = nil
        plannerCache = nil
    }

    /// A one-line description of what was applied, for the banner.
    var appliedSummary: String? {
        guard let plan else { return nil }
        switch plan.action {
        case .crash(let n): return "Crashed \(n) at \(plan.timeLiteral)"
        case .restart(let n): return "Restarted \(n) at \(plan.timeLiteral)"
        case .partition(let sel): return "Partitioned \(sel.joined(separator: ", ")) from the rest at \(plan.timeLiteral)"
        case .heal: return "Healed the partition at \(plan.timeLiteral)"
        case .dropMessage(let id): return "Dropped message #\(id) (sent at \(plan.timeLiteral))"
        }
    }

    /// "Rule broken": the banner text of the first newly broken rule.
    var brokenText: String? {
        guard let b = broken.first else { return nil }
        let more = broken.count > 1 ? " (+\(broken.count - 1) more)" : ""
        return "Your change broke: \(b.rule) at \(SimTime(microseconds: b.time))\(more)"
    }
}

extension WorkspaceModel: BreakItHost {
    var loadedRun: LoadedRun? { loaded }
    var currentFactSeq: Int? { currentFact?.seq }

    var breakItTarget: (file: String, origin: Origin)? {
        guard let s = selection, s.kind == .program, let p = activeProgram else { return nil }
        return (s.relPath == "." ? p.mainFile : s.relPath + "/" + p.mainFile, s.origin)
    }

    var hasCheckErrors: Bool {
        if coordinator.stale || coordinator.diagnostics != nil { return true }
        return problemReport?.hasErrors ?? false
    }

    var isCompareActive: Bool { compare != nil }

    struct RerunError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func rerunAndWait() async throws -> LoadedRun {
        let serial = runSerial
        run(.manual, preserveTime: true)
        await coordinator.settled()
        if coordinator.stale || runSerial == serial {
            let m = coordinator.errorMessage
                ?? coordinator.diagnostics?.diagnostics.first(where: \.isError).map { "\($0.file):\($0.line): \($0.message)" }
                ?? coordinator.rawProblems?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "The program did not run again."
            throw RerunError(message: m)
        }
        guard let run = coordinator.loaded else { throw RerunError(message: "The program did not run again.") }
        return run
    }

    func showRule(file: String, line: Int) {
        let origin = selection?.origin ?? .own
        show(source: SourceTarget(file: file, origin: origin, primary: .init(line: line, col: 1, endLine: nil, endCol: nil)))
        editor.highlight(line: line, inFile: file, origin: origin)
    }

    func clearRuleHighlight() { editor.clearHighlight() }
}
