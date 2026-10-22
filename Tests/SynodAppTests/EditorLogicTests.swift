import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

@MainActor @Suite struct EditorLogicTests {
    @Test func minimalEditTrimsPrefixAndSuffix() throws {
        let e = try #require(EditorLogic.minimalEdit(from: "hello world\n", to: "hello brave world\n"))
        #expect(e.range == NSRange(location: 6, length: 0))
        #expect(e.replacement == "brave ")
        #expect(EditorLogic.minimalEdit(from: "same", to: "same") == nil)
        let all = try #require(EditorLogic.minimalEdit(from: "abc", to: "xyz"))
        #expect(all.range == NSRange(location: 0, length: 3))
        #expect(all.replacement == "xyz")
    }

    @Test func minimalEditNeverSplitsASurrogatePair() throws {
        // 😀 and 😁 share the lead surrogate; the edit must cover the whole code point.
        let e = try #require(EditorLogic.minimalEdit(from: "a😀b", to: "a😁b"))
        #expect(e.range == NSRange(location: 1, length: 2))
        #expect(e.replacement == "😁")
        let applied = ("a😀b" as NSString).replacingCharacters(in: e.range, with: e.replacement)
        #expect(applied == "a😁b")
    }

    @Test func marksSpanTheDiagnosticAndAnEmptySpanMarksOneCharacter() throws {
        let text = "abc\ndef\n"
        let d1 = try diag(line: 2, col: 2, endLine: 2, endCol: 4, severity: "error")
        let d2 = try diag(line: 1, col: 2, endLine: 1, endCol: 2, severity: "warning")
        let marks = EditorLogic.marks(for: "p/a.synod", diagnostics: [d1, d2], positions: TextPositions(text))
        #expect(marks.count == 2)
        #expect(marks[0].range == NSRange(location: 5, length: 2))
        #expect(marks[0].kind == .error)
        #expect(marks[1].range == NSRange(location: 1, length: 1))
        #expect(marks[1].kind == .warning)
    }

    @Test func labelsInTheSameFileGetADottedMark() throws {
        let d = try diag(line: 1, col: 1, endLine: 1, endCol: 2, severity: "error",
                         labels: #"[{"file":"p/a.synod","line":2,"col":1,"end":{"line":2,"col":3},"text":"here"},{"file":"p/b.synod","line":1,"col":1,"end":{"line":1,"col":2},"text":"other"}]"#)
        let marks = EditorLogic.marks(for: "p/a.synod", diagnostics: [d], positions: TextPositions("abc\ndef\n"))
        #expect(marks.map(\.kind) == [.error, .label])
        #expect(marks[1].range == NSRange(location: 4, length: 2))
        #expect(marks[1].message == "here")
    }

    @Test func marksMoveWithEditsAndDieWhenOverlapped() {
        let marks = [
            EditorMark(range: NSRange(location: 0, length: 3), kind: .error, message: "a", hint: nil, diagnostic: nil),
            EditorMark(range: NSRange(location: 10, length: 3), kind: .error, message: "b", hint: nil, diagnostic: nil),
            EditorMark(range: NSRange(location: 5, length: 3), kind: .warning, message: "c", hint: nil, diagnostic: nil),
        ]
        // Replace [4, 6) by 5 units: the mark at 5..8 overlaps, the one at 10 moves by +3.
        let out = EditorLogic.shift(marks, replacing: NSRange(location: 4, length: 2), withLength: 5)
        #expect(out.map(\.message) == ["a", "b"])
        #expect(out[1].range.location == 13)
    }

    @Test func fixesComeFromTheDiagnosticUnderTheCaret() throws {
        let d = try diag(line: 1, col: 1, endLine: 1, endCol: 5, severity: "error",
                         help: #"[{"text":"did you mean x?","edits":[{"line":1,"col":1,"end":{"line":1,"col":5},"new":"x"}]},{"text":"read the docs","edits":[]}]"#)
        let marks = EditorLogic.marks(for: "p/a.synod", diagnostics: [d], positions: TextPositions("abcd\n"))
        let at2 = EditorLogic.fixes(in: marks, at: 2, file: "p/a.synod", origin: .own)
        #expect(at2.map(\.text) == ["did you mean x?"])
        #expect(EditorLogic.fixes(in: marks, at: 9, file: "p/a.synod", origin: .own).isEmpty)
    }

    func diag(line: Int, col: Int, endLine: Int, endCol: Int, severity: String, labels: String = "[]", help: String = "[]") throws -> CheckReport.Diagnostic {
        let json = #"{"file":"p/a.synod","line":\#(line),"col":\#(col),"end":{"line":\#(endLine),"col":\#(endCol)},"severity":"\#(severity)","code":"x","message":"msg","labels":\#(labels),"help":\#(help)}"#
        return try JSONDecoder().decode(CheckReport.Diagnostic.self, from: Data(json.utf8))
    }
}

@MainActor @Suite struct EditorHighlightTests {
    @Test func everyRoleHasItsColorAndStyle() {
        #expect(EditorHighlighter.style(for: .comment) == .init(color: .quiet, italic: true))
        #expect(EditorHighlighter.style(for: .language).color == .accent)
        #expect(EditorHighlighter.style(for: .phrase) == .init(color: .ink, semibold: true))
        #expect(EditorHighlighter.style(for: .name).color == .ink)
        #expect(EditorHighlighter.style(for: .field).color == .good)
        #expect(EditorHighlighter.style(for: .type).color == .warning)
        #expect(EditorHighlighter.style(for: .value).color == .critical)
        #expect(EditorHighlighter.style(for: .unknown).color == .ink)
        for role in SynodToken.Role.allCases {
            let a = EditorHighlighter.attributes(for: role)
            #expect(a[.foregroundColor] != nil && a[.font] != nil)
        }
    }

    @Test func lightAndDarkPalettesDiffer() {
        for entry in EditorPalette.allCases where entry != .paper || true {
            #expect(entry.hex(dark: true) != entry.hex(dark: false))
        }
        #expect(EditorPalette.paper.hex(dark: true) == 0x151A2E)
        #expect(EditorPalette.accent.hex(dark: true) == 0xF4A340)
    }

    @Test func highlightColorsEveryTokenRangeAndUnderlinesMarks() throws {
        let doc = EditorDocument(file: "p/a.synod", origin: .own, url: URL(fileURLWithPath: "/x"), text: "use std/net\n# hi 😀 x\nset a to 1\n",
                                 isReadOnly: false, groupsUndoByEvent: false)
        let tokens = [
            SynodToken(line: 1, col: 1, len: 3, role: .language),
            SynodToken(line: 1, col: 5, len: 7, role: .name),
            SynodToken(line: 2, col: 1, len: 8, role: .comment),   // includes the emoji (1 code point, 2 units)
            SynodToken(line: 3, col: 1, len: 3, role: .language),
            SynodToken(line: 3, col: 10, len: 1, role: .value),
        ]
        let diag = try JSONDecoder().decode(CheckReport.Diagnostic.self, from: Data(
            #"{"file":"p/a.synod","line":3,"col":5,"end":{"line":3,"col":6},"severity":"error","code":"e","message":"bad a"}"#.utf8))
        doc.setCheck(tokens: FileTokens(file: "p/a.synod", tokens: tokens), diagnostics: [diag], forVersion: 0)
        #expect(doc.isChecked)
        let colored = doc.applyHighlight()
        #expect(colored == 5)
        for t in doc.tokens {
            let got = doc.storage.attribute(.foregroundColor, at: t.range.location, effectiveRange: nil) as? NSColor
            #expect(got === EditorHighlighter.style(for: t.role).color.color)
        }
        let comment = try #require(doc.tokens.first { $0.role == .comment })
        #expect(comment.range.length == 9)   // 8 code points, one of them a surrogate pair
        let markAt = try #require(doc.marks.first).range.location
        #expect(doc.storage.attribute(.underlineStyle, at: markAt, effectiveRange: nil) != nil)
        #expect(doc.storage.attribute(.toolTip, at: markAt, effectiveRange: nil) as? String == "bad a")
    }

    @Test func tokensShiftWithEditsBetweenChecks() {
        let doc = EditorDocument(file: "p/a.synod", origin: .own, url: URL(fileURLWithPath: "/x"), text: "aaa bbb ccc\n",
                                 isReadOnly: false, groupsUndoByEvent: false)
        doc.setCheck(tokens: FileTokens(file: "p/a.synod", tokens: [
            SynodToken(line: 1, col: 1, len: 3, role: .name), SynodToken(line: 1, col: 5, len: 3, role: .phrase),
            SynodToken(line: 1, col: 9, len: 3, role: .value)]), diagnostics: [], forVersion: 0)
        doc.replaceText(with: "aaaXX bbb ccc\n", actionName: "Type")        // inserts after the first word
        #expect(doc.tokens.map(\.range.location) == [0, 6, 10])
        #expect(!doc.isChecked)
        doc.replaceText(with: "aaaXX bbb c\n", actionName: "Delete")         // cuts into the last token
        #expect(doc.tokens.map(\.role) == [.name, .phrase])
        #expect(doc.token(atOffset: 7)?.role == .phrase)
        #expect(doc.token(atOffset: 4) == nil)
    }

    @Test func aCheckForAnOlderVersionIsIgnored() {
        let doc = EditorDocument(file: "p/a.synod", origin: .own, url: URL(fileURLWithPath: "/x"), text: "ab\n",
                                 isReadOnly: false, groupsUndoByEvent: false)
        doc.replaceText(with: "abc\n", actionName: "Type")
        let applied = doc.setCheck(tokens: FileTokens(file: "p/a.synod", tokens: [SynodToken(line: 1, col: 1, len: 2, role: .name)]),
                                   diagnostics: [], forVersion: 0)
        #expect(!applied)
        #expect(doc.tokens.isEmpty)
        #expect(!doc.isChecked)
    }
}
