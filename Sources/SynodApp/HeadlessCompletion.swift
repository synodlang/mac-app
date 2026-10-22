import AppKit
import Foundation
import SynodCore

/// Shared by the M10 checks: prints one line per check and writes the optional JSON report.
enum HeadlessChecks {
    @MainActor
    static func finish(name: String, checks: [HeadlessEditor.Check], module: String, args: [String]) -> Int32 {
        let h = HeadlessCommands.self
        for c in checks {
            let metrics = c.metrics.sorted { $0.key < $1.key }.map { "\($0.key) \(HeadlessEditor.format($0.value))" }.joined(separator: "  ")
            h.note("\(c.ok ? "ok  " : "FAIL") \(name) \(c.name)  \(metrics)\(c.failures.isEmpty ? "" : "  " + c.failures.joined(separator: "; "))")
        }
        let report = HeadlessEditor.Report(ok: checks.allSatisfy(\.ok), module: module, checks: checks)
        if let path = h.value(of: "--report", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(report).write(to: URL(fileURLWithPath: path))
        }
        return report.ok ? 0 : 1
    }

    /// A temporary copy of `module` (removed by `cleanup`).
    static func copy(module: String, prefix: String) throws -> (root: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        let root = scratch.appendingPathComponent("module")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: (module as NSString).expandingTildeInPath), to: root)
        return (root, { try? fm.removeItem(at: scratch) })
    }
}

/// `--completion-check <module> [--report f]`: phrase completion on a temporary copy of the examples
/// (plan check 9): the scope of every file, `net.Se` accepted with placeholders, receiver and
/// qualified completion, the cached scope while a line is half typed, and the timings.
enum HeadlessCompletion {
    typealias Check = HeadlessEditor.Check

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--completion-check", in: args).first else {
            h.fail("usage: --completion-check <module> [--report file]")
            return 2
        }
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let runner = SynodRunner(executable: tools.synod)
        if let v = try? await SynodVersion.probe(runner), !v.supportsDoc {
            h.fail("this compiler does not write \(SynodVersion.docFormat)")
            return 2
        }
        let copy: (root: URL, cleanup: () -> Void)
        do { copy = try HeadlessChecks.copy(module: modulePath, prefix: "synod-completion-check") } catch {
            h.fail("cannot copy the module: \(error.localizedDescription)")
            return 2
        }
        defer { copy.cleanup() }
        let ws: Workspace
        do { ws = try Workspace.open(copy.root) } catch {
            h.fail(error.localizedDescription)
            return 2
        }
        let editor = EditorModel(workspace: ws, runner: { runner })
        editor.undoGroupsByEvent = false
        let controller = CompletionController(editor: editor)
        editor.completion = controller

        var checks: [Check] = []
        checks.append(await scopeCheck(ws: ws, controller: controller))
        checks.append(await gossipCheck(editor: editor, controller: controller))
        checks.append(await receiverCheck(editor: editor, controller: controller))
        checks.append(await qualifiedCheck(editor: editor, controller: controller))
        checks.append(await halfTypedCheck(editor: editor, controller: controller))
        checks.append(await timingCheck(ws: ws, editor: editor, controller: controller))
        return HeadlessChecks.finish(name: "completion-check", checks: checks, module: copy.root.lastPathComponent, args: args)
    }

    // MARK: Helpers

    /// Every `.synod` file of the module outside `vendor/` (module-relative, sorted).
    static func sourceFiles(_ ws: Workspace) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if let e = fm.enumerator(atPath: ws.root.path) {
            for case let p as String in e {
                if p.hasPrefix("vendor/") || p.hasPrefix("out/") || p.hasPrefix(".") { continue }
                if p.hasSuffix(".synod") { out.append(p) }
            }
        }
        return out.sorted()
    }

    /// The qualifiers a file's `use` lines give: the alias after `as`, else the last path segment.
    static func qualifiers(inSource text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 2, words[0] == "use" else { continue }
            if words.count >= 4, words[2] == "as" { out.append(words[3]) } else {
                out.append(words[1].split(separator: "/").last.map(String.init) ?? words[1])
            }
        }
        return out
    }

    /// Types `text` on a new line after `line` (same indentation as `indent`); returns the caret after it.
    @MainActor
    static func typeLine(_ doc: EditorDocument, after line: Int, indent: String, text: String) -> Int {
        let end = doc.positions.utf16LineRange(line).map { NSMaxRange($0) } ?? doc.positions.utf16Length
        let insert = "\n" + indent + text
        doc.perform(actionName: "Typing") { doc.replace(NSRange(location: end, length: 0), with: insert) }
        return end + (insert as NSString).length
    }

    @MainActor
    static func lineText(_ doc: EditorDocument, _ line: Int) -> String {
        doc.positions.utf16LineRange(line).map { (doc.text as NSString).substring(with: $0) } ?? ""
    }

    @MainActor
    static func firstLine(of doc: EditorDocument, containing needle: String) -> Int? {
        let lines = doc.text.components(separatedBy: "\n")
        return lines.firstIndex { $0.contains(needle) }.map { $0 + 1 }
    }

    static func indentOf(_ s: String) -> String { String(s.prefix { $0 == " " }) }

    // MARK: (a) the scope of every file

    @MainActor
    static func scopeCheck(ws: Workspace, controller: CompletionController) async -> Check {
        var c = Check(name: "scope of every file")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        let files = sourceFiles(ws)
        for f in files {
            guard await controller.refresh(file: f), let scope = controller.scope(for: f) else {
                fail("\(f): no scope\(controller.lastError.map { " (\($0))" } ?? "")")
                continue
            }
            let text = (try? String(contentsOf: ws.url(forRelative: f), encoding: .utf8)) ?? ""
            let want = qualifiers(inSource: text)
            let got = scope.scope?.imports.map(\.qualifier) ?? []
            if want != got { fail("\(f): imports \(got) but the source says \(want)") }
            if scope.scope?.file != f { fail("\(f): scope names \(scope.scope?.file ?? "nothing")") }
        }
        c.metrics["files"] = Double(files.count)
        if files.isEmpty { fail("no files") }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: (b) net.Se in gossip

    @MainActor
    static func gossipCheck(editor: EditorModel, controller: CompletionController) async -> Check {
        var c = Check(name: "net.Se accepts net.Send with placeholders")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let doc = try editor.open(file: "gossip/gossip.synod")
            guard let line = firstLine(of: doc, containing: "net.Send") else { fail("no net.Send line"); return c }
            let indent = indentOf(lineText(doc, line))
            let caret = typeLine(doc, after: line, indent: indent, text: "net.Se")
            guard controller.update(in: doc, caret: caret) else { fail("no items for net.Se"); return c }
            let want = "net.Send [m: msg] from [a: node] to [b: node]"
            if controller.items.first?.pattern != want { fail("first item is \(controller.items.first?.pattern ?? "none")") }
            guard let ins = controller.accept(into: doc) else { fail("accept failed"); return c }
            let newLine = lineText(doc, line + 1)
            if newLine != indent + "net.Send m from a to b" { fail("line is '\(newLine)'") }
            let ns = doc.text as NSString
            let names = doc.placeholders.ranges.map { ns.substring(with: $0) }
            if names != ["m", "a", "b"] { fail("placeholders are \(names)") }
            if doc.selection != ins.placeholders.first { fail("m is not selected") }
            if let r = doc.placeholders.next() {
                if ns.substring(with: r) != "a" { fail("Tab did not select a") }
                doc.perform(actionName: "Typing") { doc.replace(r, with: "p") }
                if lineText(doc, line + 1) != indent + "net.Send m from p to b" { fail("typing p gave '\(lineText(doc, line + 1))'") }
                if doc.placeholders.ranges.count != 3 { fail("typing cleared the placeholders") }
            } else {
                fail("Tab found no range")
            }
            doc.clearPlaceholders()
            if !doc.placeholders.isEmpty { fail("Esc did not clear") }
            // An edit outside every range clears the set as well.
            let again = typeLine(doc, after: line + 1, indent: indent, text: "net.Se")
            controller.update(in: doc, caret: again)
            _ = controller.accept(into: doc)
            let before = doc.placeholders.ranges.count
            doc.perform(actionName: "Typing") { doc.replace(NSRange(location: 0, length: 0), with: "# x\n") }
            if before != 3 || !doc.placeholders.isEmpty { fail("an edit outside the ranges left \(doc.placeholders.ranges.count) of \(before)") }
            editor.discardEditsAndReload()
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: (c) receiver completion in raft

    @MainActor
    static func receiverCheck(editor: EditorModel, controller: CompletionController) async -> Check {
        var c = Check(name: "n. offers raft's receiver phrases and fields")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let doc = try editor.open(file: "raft/raft.synod")
            guard let report = controller.scope(for: "raft/raft.synod"), let own = report.ownPackage else { fail("no scope"); return c }
            guard let line = firstLine(of: doc, containing: "define [n: Node] start") else { fail("no receiver define"); return c }
            let caret = typeLine(doc, after: line, indent: "  ", text: "n.")
            guard controller.update(in: doc, caret: caret), let req = controller.request else { fail("no items for n."); return c }
            if req.mode != .receiver { fail("mode is \(req.mode)") }
            var want = Set<String>()
            for p in own.phrases where p.receiver != nil && !p.isEvent {
                if let w = p.items.first(where: { $0.word != nil })?.word { want.insert(w) }
            }
            for f in own.node?.fields ?? [] { want.insert(f.name) }
            let got = Set(controller.items.map(\.head))
            if got != want { fail("items \(got.sorted()) but the scope has \(want.sorted())") }
            if controller.items.contains(where: { $0.pattern.hasPrefix("net.") || $0.pattern.hasPrefix("sim.") || $0.pattern.hasPrefix("lists.") }) {
                fail("a std phrase is offered")
            }
            c.metrics["items"] = Double(controller.items.count)
            controller.dismiss()
            editor.discardEditsAndReload()
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: (d) twopc.Co in the demo

    @MainActor
    static func qualifiedCheck(editor: EditorModel, controller: CompletionController) async -> Check {
        var c = Check(name: "twopc.Co accepts twopc.Coordinate")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let doc = try editor.open(file: "twopc/demo.synod")
            guard let line = firstLine(of: doc, containing: "sim.Seed") else { fail("no sim.Seed line"); return c }
            let indent = indentOf(lineText(doc, line))
            let caret = typeLine(doc, after: line, indent: indent, text: "twopc.Co")
            guard controller.update(in: doc, caret: caret) else { fail("no items for twopc.Co"); return c }
            if controller.items.first?.head != "twopc.Coordinate" { fail("first item is \(controller.items.first?.head ?? "none")") }
            _ = controller.accept(into: doc)
            let got = lineText(doc, line + 1)
            if got != indent + "twopc.Coordinate ps from c" { fail("line is '\(got)'") }
            editor.discardEditsAndReload()
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: (e) a half-typed line keeps the cached scope

    @MainActor
    static func halfTypedCheck(editor: EditorModel, controller: CompletionController) async -> Check {
        var c = Check(name: "unbalanced ( keeps the cached scope")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let doc = try editor.open(file: "gossip/gossip.synod")
            guard let before = controller.scope(for: "gossip/gossip.synod") else { fail("no scope before"); return c }
            guard let line = firstLine(of: doc, containing: "net.Send") else { fail("no net.Send line"); return c }
            let indent = indentOf(lineText(doc, line))
            _ = typeLine(doc, after: line, indent: indent, text: "set x to (lists.Size")
            guard doc.isDirty else { fail("the buffer is not dirty"); return c }
            let ok = await controller.refresh(file: "gossip/gossip.synod")
            if !ok { fail("the scope was lost") }
            if controller.scope(for: "gossip/gossip.synod") != before { fail("the scope changed") }
            if let e = controller.lastError { fail("refresh failed: \(e)") }
            if controller.diagnosticRefreshes == 0 { fail("the check did not report diagnostics") }
            let caret = typeLine(doc, after: line + 1, indent: indent, text: "net.")
            guard controller.update(in: doc, caret: caret) else { fail("no items for net."); return c }
            let netPhrases = Set(before.importedPackages.first { $0.qualifier == "net" }?.phrases.filter { $0.receiver == nil && !$0.isEvent && $0.exported }.map(\.pattern) ?? [])
            if Set(controller.items.map(\.pattern)) != netPhrases { fail("net. offers \(controller.items.count) items, the scope has \(netPhrases.count)") }
            controller.dismiss()
            editor.discardEditsAndReload()
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: (f) timings

    @MainActor
    static func timingCheck(ws: Workspace, editor: EditorModel, controller: CompletionController) async -> Check {
        var c = Check(name: "timings")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        // doc --scope of cassandra/demo.synod, saved text: the best of three (the first run warms the disk cache).
        var times: [Double] = []
        for _ in 0..<3 {
            _ = await controller.refresh(file: "cassandra/demo.synod")
            if let ms = controller.lastRefreshMs { times.append(ms) }
        }
        guard let best = times.min() else { fail("no timing"); return c }
        c.metrics["scopeMs"] = best.rounded()
        if best >= 300 { fail("doc --scope took \(Int(best)) ms") }
        // Items on the largest file.
        let files = sourceFiles(ws).filter { $0.hasSuffix(".synod") }
        let largest = files.max { a, b in
            ((try? FileManager.default.attributesOfItem(atPath: ws.url(forRelative: a).path))?[.size] as? Int ?? 0)
                < ((try? FileManager.default.attributesOfItem(atPath: ws.url(forRelative: b).path))?[.size] as? Int ?? 0)
        }
        guard let largest else { fail("no files"); return c }
        _ = await controller.refresh(file: largest)
        guard let report = controller.scope(for: largest), let text = try? String(contentsOf: ws.url(forRelative: largest), encoding: .utf8) else {
            fail("no scope for \(largest)")
            return c
        }
        let typed = text + "\n  s"
        let caret = (typed as NSString).length
        var samples: [Double] = []
        for _ in 0..<25 {
            let t0 = ContinuousClock.now
            _ = Completion.complete(in: typed, caret: caret, report: report)
            let d = ContinuousClock.now - t0
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        c.metrics["itemsMs"] = (median * 100).rounded() / 100
        if median >= 16 { fail("items took \(median) ms on \(largest)") }
        c.ok = c.failures.isEmpty
        return c
    }
}
