import Foundation
import Testing
import SynodCore
import SynodWeb
@testable import SynodApp

private let header = #"{"format":"synod-trace/1","synod":"0.2","seed":1,"program":"p","packages":["p"]}"#

private func run(_ events: [String]) throws -> LoadedRun {
    let trace = try Trace.parse(Data(([header] + events).joined(separator: "\n").utf8))
    let entries = trace.events.map { #"{"seq":\#($0.seq),"at":\#(Double($0.seq) * 10)}"# }.joined(separator: ",")
    let scene = try SceneSummary.parse(#"{"format":"synod-scene/1","duration":1000,"canvas":{"w":1,"h":1},"markers":[],"trace":[\#(entries)]}"#)
    return LoadedRun(programKey: "k", sceneText: "{}", scene: scene, trace: TraceIndex(trace: trace, scene: scene),
                     status: RunStatus.parse(""), options: RunOptions())
}

private let base = [
    #"{"seq":1,"t":0,"ev":"sim.Added","node":"n1","runs":[],"state":{}}"#,
    #"{"seq":2,"t":0,"ev":"sim.Added","node":"n2","runs":[],"state":{}}"#,
    #"{"seq":3,"t":1000,"ev":"sim.Fired","node":"n1"}"#,
]

@MainActor private final class FakeHost: BreakItHost {
    let editor: EditorModel
    var loadedRun: LoadedRun?
    var runSerial = 1
    var currentFactSeq: Int? = 3
    var breakItTarget: (file: String, origin: WorkspaceModel.Origin)? = ("main/main.synod", .own)
    var hasCheckErrors = false
    var isCompareActive = false
    var nextRun: Result<LoadedRun, Error>?
    var jumped: [Int] = []
    var shownRule: (String, Int)?
    var cleared = 0

    init(editor: EditorModel, run: LoadedRun) { self.editor = editor; loadedRun = run }

    func rerunAndWait() async throws -> LoadedRun {
        let r = try nextRun!.get()
        loadedRun = r
        runSerial += 1
        return r
    }
    func jump(toSeq seq: Int) { jumped.append(seq) }
    func showRule(file: String, line: Int) { shownRule = (file, line) }
    func clearRuleHighlight() { cleared += 1 }
    func holdFileRuns(for d: Duration) {}
}

private let source = "# package main\nuse std/sim\n\ndefine main\n  sim.StopAt 5s\n"

@MainActor
private func rig() throws -> (BreakItModel, FakeHost, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-breakit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("main"), withIntermediateDirectories: true)
    try "module example.com/t\nsynod 0.2\n".write(to: root.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
    try source.write(to: root.appendingPathComponent("main/main.synod"), atomically: true, encoding: .utf8)
    let ws = try Workspace.open(root)
    let editor = EditorModel(workspace: ws, runner: { nil })
    editor.undoGroupsByEvent = false
    let host = FakeHost(editor: editor, run: try run(base))
    let model = BreakItModel()
    model.host = host
    return (model, host, root)
}

@MainActor @Suite struct BreakItModelTests {
    @Test func boxSelectionUsesBoxCenters() {
        let boxes = [StageNodeBox(node: "a", rect: StageRect(x: 0, y: 0, w: 10, h: 10)),
                     StageNodeBox(node: "b", rect: StageRect(x: 100, y: 0, w: 10, h: 10))]
        #expect(BreakItSelection.nodes(inBox: StageRect(x: -5, y: -5, w: 30, h: 30), boxes: boxes) == ["a"])
        #expect(BreakItSelection.nodes(inBox: StageRect(x: 8, y: 0, w: 100, h: 10), boxes: boxes) == ["b"])
    }

    @Test func crashEditsSavesRerunsAndVerifies() async throws {
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        host.nextRun = .success(try run(base + [#"{"seq":4,"t":2000,"ev":"sim.Crashed","node":"n2"}"#]))
        #expect(b.availability == .available)
        #expect(b.nodeOffer("n2") == .crash)
        b.begin(.crash(node: "n2"))
        #expect(b.sheet?.plan.timeLiteral == "2ms")
        #expect(b.sheet?.plan.blockLines == ["  after 2ms", "    sim.Crash (item 1 of sim.Nodes) # n2"])
        await b.apply()
        #expect(b.outcome == .applied(seq: 4))
        #expect(host.jumped == [4])
        let disk = try String(contentsOf: root.appendingPathComponent("main/main.synod"), encoding: .utf8)
        #expect(disk.hasSuffix("  sim.StopAt 5s\n  after 2ms\n    sim.Crash (item 1 of sim.Nodes) # n2\n"))
        #expect(b.before != nil)
        #expect(b.canUndo)
        #expect(b.appliedSummary == "Crashed n2 at 2ms")
    }

    @Test func noEffectIsReportedAndUndoRestoresTheFile() async throws {
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        host.nextRun = .success(try run(base))   // no Crashed event
        b.begin(.crash(node: "n2"))
        await b.apply()
        #expect(b.outcome == .noEffect)
        host.nextRun = .success(try run(base))
        await b.undo()
        let disk = try String(contentsOf: root.appendingPathComponent("main/main.synod"), encoding: .utf8)
        #expect(disk == source)
        #expect(b.outcome == nil)
        #expect(!b.canUndo)
        #expect(b.before == nil)
    }

    @Test func newlyBrokenRulesAreShownAndOpened() async throws {
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        host.nextRun = .success(try run(base + [
            #"{"seq":4,"t":2000,"ev":"sim.Crashed","node":"n2"}"#,
            #"{"seq":5,"t":3000,"ev":"sim.Broken","rule":"main/main.synod:3: always ok"}"#]))
        b.begin(.crash(node: "n2"))
        await b.apply()
        #expect(b.broken.map(\.seq) == [5])
        #expect(b.brokenText == "Your change broke: main/main.synod:3: always ok at 3ms")
        #expect(host.shownRule?.0 == "main/main.synod" && host.shownRule?.1 == 3)
    }

    @Test func aFailedRerunReportsAndKeepsUndo() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        host.nextRun = .failure(Boom())
        b.begin(.crash(node: "n2"))
        await b.apply()
        #expect(b.outcome == .failed("boom"))
        #expect(b.canUndo)
    }

    @Test func notOfferedWithErrorsUnsavedBuffersOrReadOnly() async throws {
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        host.hasCheckErrors = true
        #expect(b.availability != .available)
        host.hasCheckErrors = false
        try await host.editor.applyEdit(file: "main/main.synod") { $0 + "\n" }
        if case .unavailable(let why) = b.availability { #expect(why.contains("Save")) } else { Issue.record("offered with an unsaved buffer") }
        host.isCompareActive = true
        if case .unavailable(let why) = b.availability { #expect(why.contains("Compare")) } else { Issue.record("offered in Compare") }
    }

    @Test func theSheetTimeIsReplannedAndValidated() throws {
        let (b, host, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root); _ = host }
        b.begin(.crash(node: "n2"))
        b.setTimeText("6s")
        #expect(b.sheet?.plan.timeLiteral == "6s")
        #expect(b.sheet?.error == nil)
        b.setTimeText("soon")
        #expect(b.sheet?.error != nil)
        #expect(b.sheet?.plan.timeLiteral == "6s")   // the last good plan stays
    }
}
