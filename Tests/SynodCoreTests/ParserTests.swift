import Foundation
import Testing

@testable import SynodCore

// MARK: JSON

@Test func jsonKeepsKeyOrderAndRawNumbers() throws {
    let v = try JSONParser.parse(#"{"b":1,"a":[true,null,"x"],"big":18446744073709551615}"#)
    #expect(v.members?.map(\.key) == ["b", "a", "big"])
    #expect(v["big"]?.uint64Value == UInt64.max)
    #expect(v["a"]?.arrayValue?.count == 3)
}

@Test func jsonEscapesAndSurrogates() throws {
    let v = try JSONParser.parse(#"["a\"b\\c\ndé😀"]"#)
    #expect(v.arrayValue?.first?.stringValue == "a\"b\\c\nd\u{e9}\u{1F600}")
}

@Test func jsonRejectsGarbage() {
    #expect(throws: JSONParseError.self) { try JSONParser.parse("{\"a\":}") }
    #expect(throws: JSONParseError.self) { try JSONParser.parse("[1,2") }
    #expect(throws: JSONParseError.self) { try JSONParser.parse("1 2") }
}

// MARK: CheckReport

@Test func checkReportDecodesEveryFixture() throws {
    let dir = Fixtures.url("synced/check")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
    #expect(names.count >= 6)
    for name in names {
        let report = try CheckReport.parse(try Data(contentsOf: dir.appendingPathComponent(name)))
        #expect(report.format == "synod-check/1", "\(name)")
        #expect(!report.diagnostics.isEmpty, "\(name)")
        #expect(report.hasErrors, "\(name)")
        for d in report.diagnostics {
            #expect(!d.file.isEmpty && d.line > 0 && d.col > 0 && !d.code.isEmpty && !d.message.isEmpty, "\(name)")
            #expect(d.end.line >= d.line, "\(name)")
        }
    }
}

@Test func checkReportKeepsLabelsHelpAndNotes() throws {
    let nodes = try CheckReport.parse(try Fixtures.data("synced/check/type-mismatch-nodes.json"))
    let first = nodes.diagnostics[0]
    #expect(first.code == "type-mismatch")
    #expect(first.file == "d/d.synod" && first.line == 11 && first.col == 27)
    #expect(first.end == SourcePosition(line: 11, col: 29))
    #expect(first.label == "has type a.Node")
    #expect(first.labels.first?.file == "b/b.synod")
    #expect(first.labels.first?.text == "expects b.Node")

    let phrase = try CheckReport.parse(try Fixtures.data("synced/check/unknown-phrase-misspelled-head.json"))
    let d = phrase.diagnostics[0]
    #expect(d.hint?.hasPrefix("did you mean") == true)
    #expect(d.help.first?.edits.first?.new == "net.Send")
    #expect(d.help.first?.edits.first?.end == SourcePosition(line: 8, col: 11))
    #expect(d.notes == ["\"net.Send\" is in std/net"])
}

@Test func checkReportIgnoresUnknownKeys() throws {
    let json = """
        {"format":"synod-check/1","ok":false,"future":{"x":1},"diagnostics":[
        {"file":"p/p.synod","line":1,"col":2,"end":{"line":1,"col":5},"severity":"warning","code":"c","message":"m","surprise":[1,2],
         "labels":[{"file":"q.synod","line":3,"col":1,"end":{"line":3,"col":2},"text":"t","more":true}]}],
         "files":[{"file":"p/p.synod","tokens":[]}]}
        """
    let r = try CheckReport.parse(Data(json.utf8))
    #expect(r.diagnostics.count == 1)
    #expect(!r.hasErrors)
    #expect(r.diagnostics[0].labels.count == 1)
}

@Test func checkReportRejectsMajorTwo() {
    let json = #"{"format":"synod-check/2","ok":true,"diagnostics":[]}"#
    #expect(throws: FormatError.self) { try CheckReport.parse(Data(json.utf8)) }
    do { _ = try CheckReport.parse(Data(json.utf8)) } catch let e as FormatError {
        #expect(e == .unsupported(format: "synod-check/2", expected: "synod-check"))
    } catch {
        Issue.record("wrong error \(error)")
    }
}

// MARK: SceneSummary

@Test func sceneSummaryOfRaft() throws {
    let s = try Fixtures.scene("raft")
    #expect(s.duration == 148332)
    #expect(s.trace.count == 2197)
    #expect(s.canvas.w == 1040 && s.canvas.h == 650)
    #expect(!s.markers.isEmpty)
    #expect(s.markers.allSatisfy { $0.known != nil })
    #expect(s.markers.contains { $0.kind == "caption" && !$0.text.isEmpty })
    #expect(s.markers.map(\.at) == s.markers.map(\.at).sorted())
    #expect(zip(s.trace, s.trace.dropFirst()).allSatisfy { $0.seq < $1.seq && $0.at <= $1.at })
}

@Test func sceneSummaryRejectsBadMajor() {
    let two = #"{"format":"synod-scene/2","duration":1,"canvas":{"w":1,"h":1},"shapes":[],"markers":[],"trace":[]}"#
    #expect(throws: FormatError.self) { try SceneSummary.parse(two) }
    #expect(throws: FormatError.self) { try SceneSummary.parse(#"{"format":"other/1","duration":1,"canvas":{"w":1,"h":1}}"#) }
    #expect(throws: (any Error).self) { try SceneSummary.parse("not json") }
}

@Test func sceneSummaryIgnoresUnknownKinds() throws {
    let s = try SceneSummary.parse(
        #"{"format":"synod-scene/1","duration":5,"canvas":{"w":2,"h":3},"x":1,"shapes":[],"markers":[{"at":1,"kind":"confetti","text":"hi"}],"trace":[]}"#)
    #expect(s.markers.first?.known == nil)
    #expect(s.markers.first?.kind == "confetti")
}

// MARK: Trace

@Test func traceHeaderAndCounts() throws {
    let raw = try Fixtures.text("synced/examples/raft/trace.jsonl")
    let trace = try Trace.parse(Data(raw.utf8))
    #expect(trace.header.seed == 3)
    #expect(trace.header.synod == "0.3")
    #expect(trace.header.program == "github.com/synodlang/examples/raft")
    #expect(trace.events.count == 2197)

    var expected: [String: Int] = [:]
    for line in raw.split(separator: "\n").dropFirst() {
        let r = line.range(of: #""ev":""#)!
        let kind = line[r.upperBound...].prefix { $0 != "\"" }
        expected[String(kind), default: 0] += 1
    }
    var got: [String: Int] = [:]
    for e in trace.events { got[e.ev, default: 0] += 1 }
    #expect(got == expected)
    #expect(trace.events.map(\.seq) == Array(1...2197))
}

@Test func traceParsesEveryFixtureKindAsTyped() throws {
    for name in Fixtures.examples {
        let trace = try Fixtures.trace(name)
        for e in trace.events {
            if case .unknown = e.payload { Issue.record("\(name): unknown payload for \(e.ev)") }
            #expect(e.extra.isEmpty, "\(name) \(e.ev) has extra keys \(e.extra.map(\.key))")
        }
    }
}

@Test func nullNodeIsNobody() throws {
    let trace = try Fixtures.trace("raft")
    let added = trace.events.first { if case .added = $0.payload { return true } else { return false } }!
    guard case .added(_, let state) = added.payload else { return }
    #expect(state.first { $0.name == "raft.VotedFor" }?.value == .node(nil))
    #expect(state.first { $0.name == "raft.VotedFor" }?.value.display == "nobody")

    let line = #"{"seq":9,"t":5,"ev":"sim.Emitted","node":null,"record":{"type":"p.Done","fields":{"n":{"node":null},"v":2}}}"#
    let e = try Trace.parseEvent(try JSONParser.parse(line), line: 2)
    #expect(e.node == nil)
    #expect(e.summaryLine == "sim.Emitted p.Done{n nobody, v 2} by nobody")
}

@Test func unknownEventKindsKeepTheirKeys() throws {
    let line = #"{"seq":3,"t":7,"ev":"sim.Teleported","node":"n2","to":"n9","weight":1.5}"#
    let e = try Trace.parseEvent(try JSONParser.parse(line), line: 2)
    #expect(e.payload == .unknown)
    #expect(e.node == "n2")
    #expect(e.extra.map(\.key) == ["to", "weight"])
    #expect(e.summaryLine == "sim.Teleported n2")
}

@Test func traceRejectsMajorTwoAndBadLines() {
    #expect(throws: FormatError.self) { try Trace.parse(Data(#"{"format":"synod-trace/2","synod":"0.2","seed":1}"#.utf8)) }
    #expect(throws: FormatError.self) { try Trace.parse(Data("{\"format\":\"synod-trace/1\",\"seed\":1}\n{oops}\n".utf8)) }
    #expect(throws: FormatError.self) { try Trace.parse(Data()) }
}

// MARK: Values and time

@Test func formatTimeTable() {
    let table: [(Int64, String)] = [
        (0, "0s"), (1, "0.001ms"), (500, "0.5ms"), (1000, "1ms"), (250_000, "250ms"), (999_999, "999.999ms"),
        (1_000_000, "1s"), (1_500_000, "1500ms"), (2_000_000, "2s"), (166_838_000, "166838ms"),
        (600_000_000, "600s"), (-1_500_000, "-1500ms"), (-2_000_000, "-2s"), (-1, "-0.001ms"),
    ]
    for (us, text) in table {
        #expect(FormatTime.string(microseconds: us) == text, "\(us)")
        #expect(FormatTime.parse(text) == us, "\(text)")
    }
    #expect(FormatTime.parse("147.98s") == 147_980_000)
    #expect(FormatTime.parse("fast") == nil)
    #expect(FormatTime.parse("12") == nil)
}

@Test func formatNumberTable() {
    let table: [(Double, String)] = [
        (0, "0"), (1, "1"), (-1, "-1"), (0.5, "0.5"), (100, "100"), (123.456, "123.456"), (-0.25, "-0.25"),
        (1e20, "100000000000000000000"), (1e21, "1e+21"), (1.5e300, "1.5e+300"), (1e-6, "0.000001"), (1e-7, "1e-7"),
        (1.5e-10, "1.5e-10"), (0.001, "0.001"), (12345678.9, "12345678.9"),
    ]
    for (d, text) in table { #expect(FormatNumber.string(d) == text, "\(d)") }
}

@Test func synodValueDisplay() throws {
    func show(_ json: String, inRecord: Bool = false) throws -> String {
        SynodValue(json: try JSONParser.parse(json), inRecord: inRecord).display
    }
    #expect(try show(#""a\"b\\c\nd""#) == #""a\"b\\c\nd""#)
    #expect(try show("3") == "3")
    #expect(try show("true") == "true")
    #expect(try show(#"{"time":20000}"#) == "20ms")
    #expect(try show(#"{"time":2000000}"#) == "2s")
    #expect(try show(#"{"node":"n3"}"#) == "n3")
    #expect(try show(#"{"node":null}"#) == "nobody")
    #expect(try show("[]") == "{}")
    #expect(try show(#"[1,"x",{"node":"n1"}]"#) == #"{1, "x", n1}"#)
    #expect(try show(#"{"map":[]}"#) == "{}")
    #expect(try show(#"{"map":[["a",1],["b",{"time":1500}]]}"#) == #"{"a": 1, "b": 1.5ms}"#)
    #expect(try show(#"{"type":"paxos.Prepare","fields":{"number":101,"secret":"…"}}"#) == "paxos.Prepare{number 101, secret …}")
    #expect(try show(#"{"type":"p.E","fields":{}}"#) == "p.E{}")
    #expect(try show(#""…""#) == #""…""#)
    #expect(try show(#""…""#, inRecord: true) == "…")
}

/// Every summary line that is a trace event must be reproduced by `summaryLine`.
@Test(arguments: Fixtures.examples)
func summaryLinesAreReproduced(example: String) throws {
    let trace = try Fixtures.trace(example)
    let lines = Set(trace.events.map(\.summaryLine))
    let summary = try Fixtures.text("synced/examples/\(example)/summary.txt")
    var checked = 0
    var addedOrChanged = 0
    for raw in summary.split(separator: "\n") where raw.hasPrefix("  ") && !raw.hasPrefix("   ") {
        let line = raw.dropFirst(2)
        // net.* lines are skipped: the trace hides message fields (`…`), the summary prints them.
        guard line.hasPrefix("sim.") || line.hasPrefix("disk.") else { continue }
        #expect(lines.contains(String(line)), "\(example): \(line)")
        checked += 1
        if line.hasPrefix("sim.Added") || line.hasPrefix("sim.Changed") { addedOrChanged += 1 }
    }
    #expect(checked > 10)
    #expect(addedOrChanged > 5)
}
