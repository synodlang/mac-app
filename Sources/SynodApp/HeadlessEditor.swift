import AppKit
import Foundation
import SynodCore
import SwiftUI
import SynodWeb

/// `--editor-check <module> [--report f]`: the editor on a temporary copy of the module. Tokens
/// arrive and color the buffer; a syntax error in the buffer gives a live diagnostic and lexical
/// tokens while the disk file stays as it was; a quick fix restores the text; saving writes the
/// file, formats it and starts a run; go to definition lands in the package file; bundled
/// examples are read-only; outside changes reload or conflict.
enum HeadlessEditor {
    struct Check: Codable {
        var name: String
        var ok = false
        var failures: [String] = []
        var metrics: [String: Double] = [:]
    }

    struct Report: Codable {
        var ok: Bool
        var module: String
        var checks: [Check]
    }

    static func run(_ args: [String]) async -> Int32 {
        let h = HeadlessCommands.self
        guard let modulePath = h.positionals(after: "--editor-check", in: args).first else {
            h.fail("usage: --editor-check <module> [--report file]")
            return 2
        }
        guard let tools = AppTools.resolve(override: ProcessInfo.processInfo.environment["SYNOD_PATH"]), tools.isUsable else {
            h.fail("the synod compiler was not found")
            return 2
        }
        let runner = SynodRunner(executable: tools.synod)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("synod-editor-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("work")
        let reference = scratch.appendingPathComponent("reference")
        do {
            let src = URL(fileURLWithPath: (modulePath as NSString).expandingTildeInPath)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: copy)
            try fm.copyItem(at: src, to: reference)
        } catch {
            h.fail("cannot copy the module: \(error.localizedDescription)")
            return 2
        }
        var checks: [Check] = []
        checks.append(await tokenCheck(copy: copy, runner: runner))
        checks.append(await renderCheck(copy: copy, runner: runner))
        checks.append(await flowCheck(copy: copy, reference: reference, runner: runner, synod: tools.synod))
        for c in checks {
            h.note("\(c.ok ? "ok  " : "FAIL") editor-check \(c.name)  \(c.metrics.sorted { $0.key < $1.key }.map { "\($0.key) \(format($0.value))" }.joined(separator: "  "))\(c.failures.isEmpty ? "" : "  " + c.failures.joined(separator: "; "))")
        }
        let report = Report(ok: checks.allSatisfy(\.ok), module: copy.lastPathComponent, checks: checks)
        if let path = h.value(of: "--report", in: args) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(report).write(to: URL(fileURLWithPath: path))
        }
        return report.ok ? 0 : 1
    }

    /// Progress lines for debugging a hang: set SYNOD_EDITOR_TRACE=1.
    static func trace(_ m: String) {
        if ProcessInfo.processInfo.environment["SYNOD_EDITOR_TRACE"] != nil { HeadlessCommands.note("trace: " + m) }
    }

    static func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    @MainActor
    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    // MARK: Tokens and highlighting

    /// (a) For every program, the tokens map to valid UTF-16 ranges whose text has `len` code
    /// points; (f) applying the highlight to the largest file takes under 16 ms.
    @MainActor
    static func tokenCheck(copy: URL, runner: SynodRunner) async -> Check {
        var c = Check(name: "tokens and highlighting")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let ws = try Workspace.open(copy)
            let checker = OverlayChecker(workspace: ws, runner: runner)
            trace("start")
            var files = Set<String>()
            var tokenCount = 0
            for program in ws.scan().programs {
                let report = try await checker.check(target: program.relPath)
                for ft in report.files {
                    guard files.insert(ft.file).inserted else { continue }
                    let text = try String(contentsOf: ws.url(forRelative: ft.file), encoding: .utf8)
                    let ns = text as NSString
                    let positions = TextPositions(text)
                    let placed = PositionedToken.place(ft.tokens, in: positions)
                    if placed.count != ft.tokens.count { fail("\(ft.file): \(ft.tokens.count - placed.count) tokens outside the text") }
                    for (t, p) in zip(ft.tokens, placed) {
                        tokenCount += 1
                        if p.range.location < 0 || NSMaxRange(p.range) > ns.length
                            || ns.substring(with: p.range).unicodeScalars.count != t.len {
                            fail("\(ft.file):\(t.line):\(t.col) token text does not have \(t.len) code points")
                            break
                        }
                    }
                }
            }
            c.metrics["files"] = Double(files.count)
            c.metrics["tokens"] = Double(tokenCount)
            if files.isEmpty || tokenCount == 0 { fail("no tokens arrived") }

            // Highlight coverage on the raft demo, through an EditorModel.
            trace("tokens done")
            let editor = EditorModel(workspace: ws, runner: { runner })
            try editor.show(file: "raft/demo.synod")
            guard let doc = editor.current else { fail("no document"); return c }
            await editor.checkNow()
            if !doc.isChecked || doc.tokens.isEmpty { fail("raft/demo.synod has no tokens") }
            doc.applyHighlight()
            var roles = Set<String>()
            var keywords = 0
            for t in doc.tokens {
                let want = EditorHighlighter.style(for: t.role).color.color
                let got = doc.storage.attribute(.foregroundColor, at: t.range.location, effectiveRange: nil) as? NSColor
                if got !== want { fail("token \(t.role) at \(t.range.location) has the wrong color"); break }
                roles.insert(t.role.rawValue)
                if t.role == .language { keywords += 1 }
            }
            c.metrics["roles"] = Double(roles.count)
            c.metrics["keywords"] = Double(keywords)
            if keywords == 0 { fail("no keyword was highlighted") }

            // The largest .synod file of the module.
            let all = files.sorted { size(ws.url(forRelative: $0)) > size(ws.url(forRelative: $1)) }
            if let largest = all.first {
                try editor.show(file: largest)
                await editor.checkNow()
                trace("largest checked \(editor.current?.file ?? "-") \(editor.current?.isChecked ?? false)")
                guard let big = editor.current, big.isChecked else { fail("\(largest) was not checked"); return c }
                    var times: [Double] = []
                for _ in 0..<7 {
                    let t0 = ContinuousClock.now
                    big.applyHighlight()
                    times.append(ms(since: t0))
                }
                times.sort()
                c.metrics["highlightMs"] = (times[times.count / 2] * 100).rounded() / 100
                c.metrics["largestLines"] = Double(big.positions.lineCount)
                if times[times.count / 2] >= 16 { fail("highlighting \(largest) took \(times[times.count / 2]) ms") }
            }
            trace("largest done")
            // Broken file: an unbalanced "(" still gets lexical tokens (decision 79).
            try editor.show(file: "raft/demo.synod")
            trace("shown")
            try await editor.applyEdit(file: "raft/demo.synod") { $0.replacingOccurrences(of: "(item 0 of raft.Leaders)", with: "(item 0 of raft.Leaders") }
            trace("applied")
            await editor.checkNow()
            if doc.tokens.isEmpty || !doc.tokens.contains(where: { $0.role == .language }) { fail("a broken file has no lexical tokens") }
            c.metrics["lexicalTokens"] = Double(doc.tokens.count)
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    // MARK: Rendering

    /// The editor view, hosted in an offscreen window, is drawn into a bitmap in both appearances:
    /// the text area (right of the gutter) must hold glyph pixels in several distinct colors.
    @MainActor
    static func renderCheck(copy: URL, runner: SynodRunner) async -> Check {
        var c = Check(name: "editor rendering")
        func fail(_ m: String) { if c.failures.count < 8 { c.failures.append(m) } }
        do {
            let ws = try Workspace.open(copy)
            let editor = EditorModel(workspace: ws, runner: { runner })
            try editor.show(file: "raft/demo.synod")
            guard let doc = editor.current else { fail("no document"); return c }
            await editor.checkNow()
            // A diagnostic underline too: break the buffer so an error mark exists.
            try await editor.applyEdit(file: "raft/demo.synod") { $0.replacingOccurrences(of: "(item 0 of raft.Leaders)", with: "(item 0 of raft.Leaders") }
            _ = await wait(3) { doc.isChecked && doc.marks.contains { $0.kind == .error } }
            doc.applyHighlight()
            let model = WorkspaceModel(workspace: ws, recordRecent: false)
            defer { model.stop() }
            try model.editor.show(file: "raft/demo.synod")
            guard let hostedDoc = model.editor.current else { fail("no hosted document"); return c }
            await model.editor.checkNow()
            try await model.editor.applyEdit(file: "raft/demo.synod") { $0.replacingOccurrences(of: "(item 0 of raft.Leaders)", with: "(item 0 of raft.Leaders") }
            _ = await wait(3) { hostedDoc.isChecked && hostedDoc.marks.contains { $0.kind == .error } }
            // Two hosts: the bare scroll view, and the SwiftUI pane as the app shows it.
            for hosted in [false, true] {
                let win = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                if hosted {
                    win.contentView = NSHostingView(rootView: EditorPane(model: model))
                } else {
                    win.contentView = EditorTextView.build(model: editor, document: doc, coordinator: EditorTextView.Coordinator(model: editor, document: doc))
                }
                win.orderFrontRegardless()
                defer { win.close() }
                for dark in [false, true] {
                    let name = (hosted ? "hosted-" : "") + (dark ? "dark" : "light")
                    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    (hosted ? hostedDoc : doc).applyHighlight()
                    try? await Task.sleep(for: .milliseconds(400))
                    win.contentView?.layoutSubtreeIfNeeded()
                    guard let tv = findTextView(in: win.contentView!) else { fail("\(name): no text view"); continue }
                    if let sc = tv.enclosingScrollView { trace("\(name) scroll \(sc.frame) content \(sc.contentView.frame) tv \(tv.frame) ruler \(String(describing: sc.verticalRulerView?.frame)) thick \(String(describing: sc.verticalRulerView?.ruleThickness))") }
                    tv.layoutSubtreeIfNeeded()
                    win.displayIfNeeded()
                    tv.enclosingScrollView?.tile()
                    // The whole view, gutter and all, as the window composes it: the text must
                    // survive what is drawn over it. Only the area right of the gutter counts.
                    guard let whole = win.contentView, let rep = whole.bitmapImageRepForCachingDisplay(in: whole.bounds) else { fail("\(name): no bitmap"); continue }
                    whole.cacheDisplay(in: whole.bounds, to: rep)
                    let scale = CGFloat(rep.pixelsWide) / whole.bounds.width
                    let firstColumn = Int((tv.enclosingScrollView?.verticalRulerView?.ruleThickness ?? 46) * scale) + Int(8 * scale)
                    let bg = EditorPalette.paper.color(dark: dark).usingColorSpace(.sRGB)!
                    var glyph = 0
                    var buckets = [UInt32: Int]()
                    for y in 0..<rep.pixelsHigh {
                        for x in firstColumn..<rep.pixelsWide {
                            guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            let d = abs(px.redComponent - bg.redComponent) + abs(px.greenComponent - bg.greenComponent) + abs(px.blueComponent - bg.blueComponent)
                            if d > 0.5 {
                                glyph += 1
                                let q = (UInt32(px.redComponent * 7) << 8) | (UInt32(px.greenComponent * 7) << 4) | UInt32(px.blueComponent * 7)
                                buckets[q, default: 0] += 1
                            }
                        }
                    }
                    // Colors that carry a real share of the glyph pixels, not antialiasing blends.
                    let distinct = buckets.values.filter { $0 >= max(20, glyph / 200) }.count
                    c.metrics["\(name)GlyphPixels"] = Double(glyph)
                    c.metrics["\(name)Colors"] = Double(distinct)
                    if glyph < 500 { fail("\(name): only \(glyph) glyph pixels in the text area") }
                    if distinct < 4 { fail("\(name): only \(distinct) distinct text colors") }
                    if let dir = ProcessInfo.processInfo.environment["SYNOD_EDITOR_PNG"], let whole = win.contentView,
                       let wrep = whole.bitmapImageRepForCachingDisplay(in: whole.bounds) {
                        whole.cacheDisplay(in: whole.bounds, to: wrep)
                        try? wrep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pane-\(name).png"))
                    }
                    if let dir = ProcessInfo.processInfo.environment["SYNOD_EDITOR_PNG"], let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("editor-\(name).png"))
                    }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    @MainActor
    static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? SynodTextView { return tv }
        for v in view.subviews { if let t = findTextView(in: v) { return t } }
        return nil
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func ms(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: The editing flow

    @MainActor
    static func flowCheck(copy: URL, reference: URL, runner: SynodRunner, synod: URL) async -> Check {
        var c = Check(name: "editing flow")
        func fail(_ m: String) { c.failures.append(m) }
        do {
            let ws = try Workspace.open(copy)
            // The tokens check broke nothing on disk (it only edited a buffer), but start clean.
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: reference, to: copy)
            let model = WorkspaceModel(workspace: ws, recordRecent: false)
            defer { model.stop() }
            guard let stage = model.stage else { fail("no stage"); return c }
            let win = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 960, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = stage.webView
            win.orderFrontRegardless()
            defer { win.close() }
            try await stage.waitUntilReady()
            let editor = model.editor
            editor.undoGroupsByEvent = false
            guard let program = model.scan.programs.first(where: { $0.name == "raft" }) else { fail("no raft program"); return c }
            let file = program.relPath == "." ? program.mainFile : program.relPath + "/" + program.mainFile
            let url = ws.url(forRelative: file)
            let original = try String(contentsOf: url, encoding: .utf8)
            let originalData = try Data(contentsOf: url)

            model.select(.init(origin: .own, kind: .program, relPath: program.relPath))
            guard let doc = editor.current, doc.file == file else { fail("the editor did not open \(file)"); return c }
            if !(await wait(20) { model.loaded != nil && !model.coordinator.isRunning }) { fail("the first run did not finish"); return c }
            if !(await wait(5) { doc.isChecked && !doc.tokens.isEmpty }) { fail("no tokens for \(file)"); return c }
            c.metrics["tokens"] = Double(doc.tokens.count)
            if doc.isDirty { fail("a freshly opened buffer is dirty") }

            trace("(b) Live")
            // (b) Live diagnostics: a syntax error is underlined within 2 s; the disk is untouched.
            let broken = original.replacingOccurrences(of: "(item 0 of raft.Leaders)", with: "(item 0 of raft.Leaders")
            let brokenLine = (broken.components(separatedBy: "\n").firstIndex { $0.contains("(item 0 of raft.Leaders") } ?? -1) + 1
            let runsBefore = model.coordinator.generation
            try await editor.applyEdit(file: file, actionName: "Break") { _ in broken }
            let t0 = ContinuousClock.now
            if !doc.isDirty { fail("the edited buffer is not dirty") }
            let live = await wait(2) { doc.isChecked && doc.marks.contains { $0.kind == .error } }
            c.metrics["liveDiagnosticMs"] = (ms(since: t0) * 10).rounded() / 10
            if !live { fail("no live diagnostic within 2 s") }
            if let m = doc.marks.first(where: { $0.kind == .error }), let d = m.diagnostic {
                if d.line != brokenLine { fail("diagnostic on line \(d.line), expected \(brokenLine)") }
                let want = doc.positions.utf16Range(from: SourcePosition(line: d.line, col: d.col), to: d.end)
                if want != m.range { fail("underline \(m.range) differs from the diagnostic span \(String(describing: want))") }
                c.metrics["diagnosticLine"] = Double(d.line)
            }
            if !doc.tokens.isEmpty, doc.tokens.allSatisfy({ [.language, .value, .comment, .name].contains($0.role) }) {
                c.metrics["lexicalTokens"] = Double(doc.tokens.count)
            } else { fail("a broken buffer should have lexical tokens only") }
            if (try Data(contentsOf: url)) != originalData { fail("the overlay check changed the file on disk") }
            if let r = editor.programReport, r.hasErrors {} else { fail("the program report has no error") }
            if model.problemReport?.hasErrors != true { fail("the Problems list does not show the unsaved error") }
            if model.coordinator.generation != runsBefore { fail("an unsaved buffer started a run") }

            trace("Undo works")
            // Undo works and the buffer is clean again.
            doc.undoManager.undo()
            if doc.text != original { fail("undo did not restore the text") }
            if doc.isDirty { fail("the buffer is dirty after undo") }

            trace("(c) Quick fix")
            // (c) Quick fix: the misspelling's help restores the original byte for byte.
            try await editor.applyEdit(file: file, actionName: "Misspell") { $0.replacingOccurrences(of: "sim.Crash old", with: "sim.Crsh old") }
            _ = await wait(2) { doc.isChecked && doc.marks.contains { $0.diagnostic?.code == "unknown-phrase" } }
            guard let mark = doc.marks.first(where: { $0.diagnostic?.code == "unknown-phrase" }) else { fail("no unknown-phrase diagnostic"); return c }
            let fixes = doc.fixes(atOffset: mark.range.location + 1)
            c.metrics["fixes"] = Double(fixes.count)
            guard let fix = fixes.first else { fail("no quick fix at the misspelling"); return c }
            if doc.text == original { fail("buffer changed before the fix") }
            try editor.apply(fix)
            if doc.text != original { fail("the fix did not restore the original text") }
            if (try Data(contentsOf: url)) != originalData { fail("the quick fix wrote the file") }
            doc.undoManager.undo()
            if !doc.text.contains("sim.Crsh") { fail("undo of the fix did not bring back the misspelling") }
            doc.undoManager.redo()
            if doc.text != original { fail("redo of the fix did not restore the text") }

            trace("(d) Format")
            // (d) Format on save: an unsorted import and a double space, saved, give `synod fmt` output.
            let messy = original
                .replacingOccurrences(of: "use std/lesson\nuse std/net\n", with: "use std/net\nuse std/lesson\n")
                .replacingOccurrences(of: "set nodes to (", with: "set nodes to   (")
            if messy == original { fail("the messy text equals the original") }
            let expected = try expectedFormat(of: messy, file: file, reference: reference, synod: synod)
            try await editor.applyEdit(file: file, actionName: "Mess up") { _ in messy }
            doc.requestSelection(NSRange(location: 3, length: 0))
            let genBefore = model.coordinator.generation
            let result = try await editor.save(file: file)
            if result != .saved(formatted: true) { fail("save result \(result)") }
            let disk = try String(contentsOf: url, encoding: .utf8)
            if disk != expected { fail("the saved file is not the `synod fmt` output") }
            if doc.text != disk || doc.isDirty { fail("the buffer does not match the formatted file") }
            if doc.undoManager.undoActionName != "Format" { fail("the format change is not one undo step named Format (\(doc.undoManager.undoActionName))") }
            if disk != original { fail("the formatted file differs from the canonical original") }
            let rerun = await wait(2) { model.coordinator.generation > genBefore }
            c.metrics["rerunStarted"] = rerun ? 1 : 0
            if !rerun { fail("no run started within 2 s of the save") }
            if !(await wait(20) { !model.coordinator.isRunning && model.loaded != nil }) { fail("the run after saving did not finish") }

            trace("fmt refuses")
            // fmt refuses a file with errors: the file stays as written and its output shows.
            try await editor.applyEdit(file: file, actionName: "Break") { _ in broken }
            let refused = try await editor.save(file: file)
            if case .formatRefused = refused {} else { fail("fmt did not refuse a broken file: \(refused)") }
            if (try String(contentsOf: url, encoding: .utf8)) != broken { fail("the broken file was not kept as written") }
            if doc.isDirty { fail("a saved broken buffer is dirty") }
            doc.undoManager.undo()
            try await editor.save(file: file)
            if (try String(contentsOf: url, encoding: .utf8)) != original { fail("the file was not restored") }
            _ = await wait(20) { !model.coordinator.isRunning && model.coordinator.generation > genBefore }

            // (e) Help edit from a run diagnostic reaches the Problems fixes too.
            trace("Go to definition: a p")
            // Go to definition: a phrase use lands in the package file.
            if !(await wait(5) { doc.isChecked }) { fail("buffer not checked before go to definition") }
            guard let use = doc.tokens.first(where: { $0.role == .phrase && $0.def != nil && $0.def?.file != file }) else {
                fail("no phrase use with a definition in another file")
                return c
            }
            let target = use.def!
            if try !editor.goToDefinition(in: doc, atOffset: use.range.location) { fail("go to definition found nothing") }
            if editor.current?.file != CheckReport.workspacePath(ofDefinitionFile: target.file) { fail("went to \(editor.current?.file ?? "nothing"), expected \(target.file)") }
            if editor.reveal?.line != target.line { fail("revealed line \(String(describing: editor.reveal?.line)), expected \(target.line)") }
            c.metrics["definitionLine"] = Double(target.line)
            try editor.show(file: file)

            trace("Outside changes")
            // Outside changes: a clean buffer reloads; a dirty one asks.
            try await externalChanges(editor: editor, ws: ws, fail: fail)

            trace("Read-only")
            // Read-only: bundled examples cannot be edited or saved.
            if let exWs = model.examples {
                let exFile = file
                let ro = try editor.open(file: exFile, origin: .examples)
                if !ro.isReadOnly { fail("an example buffer is editable") }
                do { try await editor.save(file: exFile, origin: .examples); fail("saving an example succeeded") } catch {}
                do { try await editor.applyEdit(file: exFile, origin: .examples) { $0 + "x" }; fail("editing an example succeeded") } catch {}
                _ = exWs
            } else {
                c.metrics["noBundledExamples"] = 1
            }

            // Nothing was written to out/.
            if FileManager.default.fileExists(atPath: copy.appendingPathComponent("out").path) { fail("an out/ folder appeared") }
            let overlay = OverlayChecker(workspace: ws, runner: runner).overlayFolder
            let left = (try? FileManager.default.contentsOfDirectory(atPath: overlay.path)) ?? []
            if !left.isEmpty { fail("overlay files were left behind: \(left)") }
        } catch {
            fail(error.localizedDescription)
        }
        c.ok = c.failures.isEmpty
        return c
    }

    /// What `synod fmt` makes of `text`, run in the reference copy of the module.
    @MainActor
    static func expectedFormat(of text: String, file: String, reference: URL, synod: URL) throws -> String {
        let ws = try Workspace.open(reference)
        let url = ws.url(forRelative: file)
        try Data(text.utf8).write(to: url)
        let p = Process()
        p.executableURL = synod
        p.arguments = ["fmt", file, "--style", "short", "--color", "never"]
        p.currentDirectoryURL = reference
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    static func externalChanges(editor: EditorModel, ws: Workspace, fail: (String) -> Void) async throws {
        let file = "raft/raft.synod"
        let doc = try editor.open(file: file)
        let url = ws.url(forRelative: file)
        let original = try String(contentsOf: url, encoding: .utf8)
        defer { try? Data(original.utf8).write(to: url) }
        try Data((original + "# changed outside\n").utf8).write(to: url)
        editor.diskChanged()
        if doc.text != original + "# changed outside\n" { fail("a clean buffer did not reload") }
        if doc.isDirty { fail("a reloaded buffer is dirty") }
        try await editor.applyEdit(file: file) { $0 + "# mine\n" }
        try Data((original + "# changed again\n").utf8).write(to: url)
        editor.diskChanged()
        if doc.conflict == nil { fail("a dirty buffer did not get a conflict") }
        if !doc.text.hasSuffix("# mine\n") { fail("a dirty buffer lost its text") }
        editor.keepMine(doc)
        if doc.conflict != nil || !doc.isDirty { fail("keep mine did not keep the buffer") }
        editor.reloadFromDisk(doc)
        if doc.text != original + "# changed again\n" || doc.isDirty { fail("reload did not take the disk text") }
    }
}
