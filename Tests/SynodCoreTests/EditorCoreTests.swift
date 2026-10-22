import Foundation
import Testing

@testable import SynodCore

// MARK: Tokens and the check report

@Test func checkReportDecodesFilesAndIgnoresUnknownKeys() throws {
    let report = try CheckReport.parse(try Fixtures.data("own/check-tokens.json"))
    #expect(report.ok && report.diagnostics.isEmpty)
    #expect(report.files.map(\.file) == ["p/demo.synod", "p/p.synod"])
    let demo = try #require(report.tokens(for: "p/demo.synod"))
    #expect(demo.tokens.count == 8)
    #expect(demo.tokens[0] == SynodToken(line: 1, col: 1, len: 14, role: .comment))
    #expect(demo.tokens[4].def == TokenDefinition(file: "p/p.synod", line: 3, col: 1))
    #expect(demo.tokens[6].def?.file == "github.com/x/y@v1.0.0/y.synod")
    #expect(demo.tokens[7].role == .unknown, "a role this build does not know")
    #expect(!demo.looksLexicalOnly)
    #expect(report.tokens(for: "nope.synod") == nil)
}

@Test func checkReportWithoutTokensHasNoFiles() throws {
    let report = try CheckReport.parse(try Fixtures.data("synced/check/indent-tab.json"))
    #expect(report.files.isEmpty)
    #expect(report.hasErrors)
}

@Test func lexicalOnlyFilesAreRecognised() throws {
    let json = #"""
    {"format":"synod-check/1","ok":false,"diagnostics":[],"files":[{"file":"a.synod","tokens":[
     {"line":1,"col":1,"len":14,"role":"comment"},{"line":2,"col":1,"len":3,"role":"language"},
     {"line":2,"col":5,"len":4,"role":"name"},{"line":3,"col":1,"len":2,"role":"value"}]},
     {"file":"empty.synod","tokens":[]},{"file":"none.synod"}]}
    """#
    let report = try CheckReport.parse(Data(json.utf8))
    #expect(report.files[0].looksLexicalOnly)
    #expect(report.files[1].tokens.isEmpty && report.files[2].tokens.isEmpty)
}

@Test func tokenLookupByPosition() throws {
    let file = try #require(try CheckReport.parse(try Fixtures.data("own/check-tokens.json")).tokens(for: "p/demo.synod"))
    #expect(file.token(atLine: 2, col: 1)?.role == .language)
    #expect(file.token(atLine: 2, col: 3)?.role == .language, "inside the token")
    #expect(file.token(atLine: 2, col: 4) == nil, "between tokens")
    #expect(file.token(atLine: 2, col: 5)?.role == .name)
    #expect(file.token(atLine: 5, col: 9)?.role == .field)
    #expect(file.token(atLine: 1, col: 15) == nil, "just after the last character")
    #expect(file.token(atLine: 9, col: 1) == nil)
}

@Test func vendoredDefinitionsResolveUnderVendor() {
    #expect(CheckReport.workspacePath(ofDefinitionFile: "github.com/x/y@v1.0.0/y.synod") == "vendor/github.com/x/y@v1.0.0/y.synod")
    #expect(CheckReport.workspacePath(ofDefinitionFile: "vendor/github.com/x/y@v1.0.0/y.synod") == "vendor/github.com/x/y@v1.0.0/y.synod")
    #expect(CheckReport.workspacePath(ofDefinitionFile: "tcp/tcp.synod") == "tcp/tcp.synod")
}

// MARK: Positions

private let mixed = "# héllo 😀 世界\nuse x\n"

@Test func positionsMapCodePointsToUTF16AndUTF8() throws {
    let p = TextPositions(mixed)
    #expect(p.lineCount == 3)
    #expect(p.utf16Offset(line: 1, col: 1) == 0)
    #expect(p.utf16Offset(line: 1, col: 4) == 3, "é is one unit")
    #expect(p.utf16Offset(line: 1, col: 9) == 8, "the emoji starts")
    #expect(p.utf16Offset(line: 1, col: 10) == 10, "an astral scalar is two units")
    #expect(p.utf16Offset(line: 1, col: 11) == 11)
    #expect(p.utf8Offset(line: 1, col: 4) == 3, "é is two bytes")
    #expect(p.utf8Offset(line: 1, col: 11) == 14, "the emoji is four bytes")
    #expect(p.utf8Offset(line: 1, col: 12) == 17, "a CJK character is three bytes")
    // Line 2 starts after 13 units + newline, or 21 bytes (… 世界 = 6 bytes at 14..20, then \n).
    #expect(p.utf16Offset(line: 2, col: 1) == 14)
    #expect(p.utf8Offset(line: 2, col: 1) == 21)
    #expect(p.utf16Length == 20 && p.utf8Length == 27)
    // A range of code points covers both units of the emoji.
    #expect(p.utf16Range(line: 1, col: 9, len: 1) == NSRange(location: 8, length: 2))
    #expect(p.utf16Range(line: 1, col: 9, len: 3) == NSRange(location: 8, length: 4))
    #expect(p.utf16Range(from: SourcePosition(line: 1, col: 11), to: SourcePosition(line: 2, col: 4)) == NSRange(location: 11, length: 6))
    #expect(p.utf16LineRange(1) == NSRange(location: 0, length: 13))
    #expect(p.utf16LineRange(3) == NSRange(location: 20, length: 0))
}

@Test func positionsRoundTripAndRejectNonBoundaries() throws {
    let p = TextPositions(mixed)
    let ns = mixed as NSString
    // Every scalar start round-trips; offsets inside a surrogate pair or a UTF-8 sequence are nil.
    var checked = 0
    for line in 1...p.lineCount {
        var col = 1
        while let off = p.utf16Offset(line: line, col: col) {
            #expect(p.position(utf16Offset: off) == SourcePosition(line: line, col: col))
            if let u8 = p.utf8Offset(line: line, col: col) { #expect(p.position(utf8Offset: u8) == SourcePosition(line: line, col: col)) }
            checked += 1
            col += 1
        }
    }
    #expect(checked == 20)
    #expect(p.position(utf16Offset: 9) == nil, "inside the emoji")
    #expect(p.position(utf8Offset: 4) == nil, "inside é")
    #expect(p.position(utf16Offset: -1) == nil)
    #expect(p.position(utf16Offset: ns.length + 1) == nil)
    #expect(p.position(utf16Offset: ns.length) == SourcePosition(line: 3, col: 1))
    #expect(p.utf16Offset(utf8Offset: 14) == 11)
    #expect(p.utf16Offset(utf8Offset: 15) == nil)
}

@Test func positionsRejectOutOfRange() {
    let p = TextPositions("ab\ncd")
    #expect(p.lineCount == 2)
    #expect(p.utf16Offset(line: 1, col: 3) == 2, "just after the last character of a line")
    #expect(p.utf16Offset(line: 1, col: 4) == nil)
    #expect(p.utf16Offset(line: 2, col: 3) == 5, "the end of the text")
    #expect(p.utf16Offset(line: 3, col: 1) == nil)
    #expect(p.utf16Offset(line: 0, col: 1) == nil)
    #expect(p.utf16Offset(line: 1, col: 0) == nil)
    #expect(p.utf16Range(line: 2, col: 1, len: 3) == nil)
    #expect(TextPositions("").lineCount == 1)
    #expect(TextPositions("").utf16Offset(line: 1, col: 1) == 0)
}

@Test func tokensArePlacedInTheText() throws {
    let text = "# héllo 😀\nuse x\n"
    let p = TextPositions(text)
    let tokens = [SynodToken(line: 1, col: 3, len: 5, role: .name), SynodToken(line: 1, col: 9, len: 1, role: .value), SynodToken(line: 2, col: 1, len: 3, role: .language),
        SynodToken(line: 9, col: 1, len: 3, role: .language)]
    let placed = PositionedToken.place(tokens, in: p)
    #expect(placed.count == 3, "a token outside the text is left out")
    let ns = text as NSString
    #expect(placed.map { ns.substring(with: $0.range) } == ["héllo", "😀", "use"])
}

// MARK: Token shifting

@Test func shiftingInsertDeleteReplace() {
    // "aa bb cc": aa [0,2), bb [3,5), cc [6,8)
    let toks = [PositionedToken(range: NSRange(location: 0, length: 2), role: .name), PositionedToken(range: NSRange(location: 3, length: 2), role: .phrase),
        PositionedToken(range: NSRange(location: 6, length: 2), role: .field)]
    func ranges(_ t: [PositionedToken]) -> [NSRange] { t.map(\.range) }

    // Insert before a token: it and the ones after shift.
    var r = TokenShifter.shift(toks, replacing: NSRange(location: 3, length: 0), withLength: 2)
    #expect(ranges(r) == [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2), NSRange(location: 8, length: 2)])
    // Insert right after a token: it stays.
    r = TokenShifter.shift(toks, replacing: NSRange(location: 2, length: 0), withLength: 1)
    #expect(ranges(r) == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 7, length: 2)])
    // Insert inside a token: dropped.
    r = TokenShifter.shift(toks, replacing: NSRange(location: 4, length: 0), withLength: 3)
    #expect(ranges(r) == [NSRange(location: 0, length: 2), NSRange(location: 9, length: 2)])
    #expect(r.map(\.role) == [.name, .field])
    // Delete the space and bb: bb dropped, cc moves left.
    r = TokenShifter.shift(toks, replacing: NSRange(location: 2, length: 3), withLength: 0)
    #expect(ranges(r) == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
    // Replace across two tokens with shorter text.
    r = TokenShifter.shift(toks, replacing: NSRange(location: 1, length: 6), withLength: 1)
    #expect(r.isEmpty, "aa, bb and cc all overlap [1,7)")
    // Replace a token exactly: the old token goes.
    r = TokenShifter.shift(toks, replacing: NSRange(location: 3, length: 2), withLength: 5)
    #expect(ranges(r) == [NSRange(location: 0, length: 2), NSRange(location: 9, length: 2)])
    // Several edits in sequence.
    r = TokenShifter.shift(toks, edits: [TextEdit(range: NSRange(location: 0, length: 0), replacement: ">>"), TextEdit(range: NSRange(location: 8, length: 0), replacement: "z")])
    #expect(ranges(r) == [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2), NSRange(location: 9, length: 2)])
}

@Test func shiftedTokensStillSpellTheirWords() {
    var rng = SplitMix(seed: 42)
    let alphabet = Array("abcdefg  \n😀é")
    func randomText(_ n: Int) -> String { String((0..<n).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }) }
    for _ in 0..<300 {
        let text = randomText(Int(rng.next() % 40) + 1)
        let ns = text as NSString
        // Tokens: maximal runs of letters.
        var toks: [PositionedToken] = []
        var i = 0
        while i < ns.length {
            var j = i
            while j < ns.length, (97...103).contains(ns.character(at: j)) { j += 1 }
            if j > i { toks.append(PositionedToken(range: NSRange(location: i, length: j - i), role: .name)) }
            i = max(j, i + 1)
        }
        let a = Int(rng.next() % UInt64(ns.length + 1))
        let b = min(ns.length, a + Int(rng.next() % 6))
        // Keep the edit off surrogate halves so the new text is well formed.
        if a < ns.length, UTF16.isTrailSurrogate(ns.character(at: a)) { continue }
        if b < ns.length, UTF16.isTrailSurrogate(ns.character(at: b)) { continue }
        let replacement = ["", "x", "xyz", "ab cd"][Int(rng.next() % 4)]
        let edit = TextEdit(range: NSRange(location: a, length: b - a), replacement: replacement)
        let new = TextEdit.apply([edit], to: text) as NSString
        let shifted = TokenShifter.shift(toks, replacing: edit.range, withLength: edit.replacementLength)
        // Kept tokens are those that do not overlap the edit; they still spell the same word.
        let delta = edit.replacementLength - edit.range.length
        var expected: [NSRange] = []
        for t in toks {
            let s = t.range.location, e = s + t.range.length
            if e <= a { expected.append(t.range) } else if s >= b { expected.append(NSRange(location: s + delta, length: t.range.length)) }
        }
        #expect(shifted.map(\.range) == expected)
        let keptOld = toks.filter { $0.range.location + $0.range.length <= a || $0.range.location >= b }
        for (t, old) in zip(shifted, keptOld) { #expect(new.substring(with: t.range) == ns.substring(with: old.range)) }
    }
}

@Test func helpEditsApplyInDescendingOrder() throws {
    let text = "aXb\nuse y\n"
    let json = #"""
    {"format":"synod-check/1","ok":false,"diagnostics":[{"file":"f.synod","line":1,"col":2,"end":{"line":1,"col":3},"severity":"error","code":"c","message":"m",
      "help":[{"text":"fix","edits":[{"line":1,"col":2,"end":{"line":1,"col":3},"new":"Y"},{"line":2,"col":1,"end":{"line":2,"col":1},"new":"use z\n"},{"line":2,"col":1,"end":{"line":2,"col":1},"new":"use q\n"}]}]}]}
    """#
    let help = try #require(try CheckReport.parse(Data(json.utf8)).diagnostics.first?.help.first)
    let edits = try #require(TextEdit.edits(from: help, in: TextPositions(text)))
    #expect(edits.map(\.range.location) == [4, 4, 1])
    #expect(TextEdit.apply(edits, to: text) == "aYb\nuse z\nuse q\nuse y\n")
    let bad = CheckReport.Help.testing(edits: [(9, 1, 9, 2, "x")])
    #expect(TextEdit.edits(from: bad, in: TextPositions(text)) == nil)
}

private extension CheckReport.Help {
    static func testing(edits: [(Int, Int, Int, Int, String)]) -> CheckReport.Help {
        let list = edits.map { #"{"line":\#($0.0),"col":\#($0.1),"end":{"line":\#($0.2),"col":\#($0.3)},"new":"\#($0.4)"}"# }.joined(separator: ",")
        return try! JSONDecoder().decode(CheckReport.Help.self, from: Data(#"{"text":"t","edits":[\#(list)]}"#.utf8))
    }
}

// MARK: Overlay checks

private struct EditorFixture {
    let dir: URL
    let workspace: Workspace
    let cache: CachePaths
    let argsFile: URL

    init() throws {
        dir = try makeTempDir()
        let module = dir.appendingPathComponent("module")
        _ = try makeMiniModule(in: module)
        workspace = try Workspace.open(module)
        cache = CachePaths.under(dir)
        argsFile = dir.appendingPathComponent("args.txt")
    }

    func checker(_ mode: String = "ok", extra: [String: String] = [:]) -> OverlayChecker {
        OverlayChecker(workspace: workspace, runner: fakeRunner(mode, argsFile: argsFile, extra: extra), cache: cache)
    }

    var calls: [String] { ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Test func overlayFileIsWrittenAsSpecified() throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let overlay = try fx.checker().writeOverlay(buffers: ["raft/demo.synod": "# package main\nuse a\n", "raft/raft.synod": "# package raft\n"])
    let folder = overlay.deletingLastPathComponent()
    #expect(overlay.lastPathComponent == "overlay.json")
    #expect(folder.deletingLastPathComponent().path == fx.checker().overlayFolder.path)
    #expect(fx.checker().overlayFolder.path.hasPrefix(fx.cache.cacheRoot.appendingPathComponent("overlay").path))
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: overlay)) as? [String: Any])
    #expect(doc["format"] as? String == "synod-overlay/1")
    let replace = try #require(doc["replace"] as? [String: String])
    #expect(Set(replace.keys) == ["raft/demo.synod", "raft/raft.synod"])
    #expect(try String(contentsOfFile: replace["raft/demo.synod"]!, encoding: .utf8) == "# package main\nuse a\n")
    #expect(try String(contentsOfFile: replace["raft/raft.synod"]!, encoding: .utf8) == "# package raft\n")
    #expect(replace["raft/demo.synod"]!.hasPrefix(folder.path), "values are absolute paths of files next to overlay.json")
    let raw = try String(contentsOf: overlay, encoding: .utf8)
    #expect(!raw.contains("\\/"), "slashes are not escaped")
}

@Test func overlayCheckInvokesSynodAndCleansUp() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let out = fx.dir.appendingPathComponent("seen")
    let report = try await fx.checker(extra: ["FAKE_OVERLAY_OUT": out.path]).check(target: "raft", buffers: ["raft/demo.synod": "# package main\nSTART\n"])
    #expect(report.files.count == 2, "tokens come back with the report")
    let call = try #require(fx.calls.first)
    #expect(call.hasPrefix("check --json --tokens --overlay "))
    #expect(call.hasSuffix("/overlay.json raft"))
    // While the call ran, the folder held overlay.json and the buffer.
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("overlay.json"))) as? [String: Any])
    #expect(doc["format"] as? String == "synod-overlay/1")
    #expect(try String(contentsOf: out.appendingPathComponent("1.synod"), encoding: .utf8) == "# package main\nSTART\n")
    // Afterwards nothing is left in the cache, and the workspace is untouched.
    let left = (try? FileManager.default.contentsOfDirectory(atPath: fx.checker().overlayFolder.path)) ?? []
    #expect(left.isEmpty)
    #expect(try String(contentsOf: fx.workspace.url(forRelative: "raft/demo.synod"), encoding: .utf8) == "# package main\nuse example.com/mini/raft\n")
}

@Test func checkWithoutBuffersPassesNoOverlay() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    _ = try await fx.checker().check(target: "raftlook")
    #expect(fx.calls == ["check --json --tokens raftlook"])
}

@Test func overlayCheckReportsDiagnosticsAndToolErrors() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let report = try await fx.checker("diag").check(target: "raft", buffers: ["raft/demo.synod": "x"])
    #expect(report.hasErrors)
    await #expect(throws: PipelineError.self) { try await fx.checker("tool-error").check(target: "raft", buffers: ["raft/demo.synod": "x"]) }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: fx.checker().overlayFolder.path)) ?? []
    #expect(left.isEmpty, "the folder is removed after a failure too")
}

@Test func cancellingAnOverlayCheckStopsIt() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let checker = fx.checker("sleep")
    let task = Task { try await checker.check(target: "raft", buffers: ["raft/demo.synod": "x"]) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: fx.checker().overlayFolder.path)) ?? []
    #expect(left.isEmpty)
}

// MARK: Formatter

@Test func formatterRunsFmtWithShortStyle() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let fmt = Formatter(workspace: fx.workspace, runner: fakeRunner("ok", argsFile: fx.argsFile))
    let outcome = try await fmt.format(relativePath: "raft/demo.synod")
    #expect(outcome == .formatted(changed: false))
    #expect(fx.calls == ["fmt raft/demo.synod --style short --color never"])
    #expect(Formatter.arguments(relativePath: "a/b.synod") == ["fmt", "a/b.synod", "--style", "short", "--color", "never"])
}

@Test func formatterReportsChangesAndRefusals() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let changed = Formatter(workspace: fx.workspace, runner: fakeRunner("ok", extra: ["FAKE_FMT_APPEND": "# tidy\n"]))
    #expect(try await changed.format(relativePath: "raft/demo.synod") == .formatted(changed: true))
    #expect(try String(contentsOf: fx.workspace.url(forRelative: "raft/demo.synod"), encoding: .utf8).hasSuffix("# tidy\n"))

    let refused = Formatter(workspace: fx.workspace, runner: fakeRunner("ok", extra: ["FAKE_FMT_EXIT": "1"]))
    guard case .refused(let output) = try await refused.format(relativePath: "raft/demo.synod") else { Issue.record("expected .refused"); return }
    #expect(output.contains("cannot format"))

    let broken = Formatter(workspace: fx.workspace, runner: fakeRunner("ok", extra: ["FAKE_FMT_EXIT": "2"]))
    await #expect(throws: PipelineError.self) { try await broken.format(relativePath: "raft/demo.synod") }
}

// MARK: RunPipeline.runDetailed

@Test func runDetailedReturnsTokensWithTheOutcome() async throws {
    let fx = try EditorFixture()
    defer { fx.cleanup() }
    let pipeline = RunPipeline(workspace: fx.workspace, runner: fakeRunner("ok", argsFile: fx.argsFile), cache: fx.cache)
    let program = fx.workspace.scan().programs.first { $0.relPath == "raft" }!
    let result = try await pipeline.runDetailed(program: program)
    guard case .ran = result.outcome else { Issue.record("not ran"); return }
    #expect(result.check?.files.count == 2)
    #expect(fx.calls.first == "check --json --tokens raft")

    let diag = try await RunPipeline(workspace: fx.workspace, runner: fakeRunner("diag"), cache: fx.cache).runDetailed(program: program)
    guard case .diagnostics(let report) = diag.outcome else { Issue.record("not diagnostics"); return }
    #expect(diag.check == report)

    let plain = try await pipeline.run(program: program)
    guard case .ran = plain else { Issue.record("run keeps working"); return }
}
