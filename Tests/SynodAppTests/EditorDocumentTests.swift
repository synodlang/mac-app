import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

@MainActor
private func makeDoc(_ text: String, readOnly: Bool = false) -> EditorDocument {
    EditorDocument(file: "p/a.synod", origin: .own, url: URL(fileURLWithPath: "/nonexistent/a.synod"), text: text, isReadOnly: readOnly, groupsUndoByEvent: false)
}

@MainActor @Suite struct EditorDocumentTests {
    @Test func startsCleanAndTracksDirtyAgainstSavedText() {
        let doc = makeDoc("abc\n")
        #expect(!doc.isDirty)
        #expect(doc.version == 0)
        doc.perform(actionName: "Edit") { doc.replace(NSRange(location: 3, length: 0), with: "d") }
        #expect(doc.text == "abcd\n")
        #expect(doc.isDirty)
        #expect(doc.version == 1)
        doc.markSaved("abcd\n")
        #expect(!doc.isDirty)
        doc.undoManager.undo()
        #expect(doc.text == "abc\n")
        #expect(doc.isDirty)
        doc.undoManager.redo()
        #expect(doc.text == "abcd\n")
        #expect(!doc.isDirty)
    }
}

@MainActor @Suite struct EditorUndoTests {
    @Test func helpEditsAreOneUndoStepAndRedoable() throws {
        let doc = makeDoc("sim.Crsh old\nsim.Crsh two\n")
        let help = CheckReport.Help.test(edits: [(1, 1, 1, 9, "sim.Crash"), (2, 1, 2, 9, "sim.Crash")])
        let edits = try #require(TextEdit.edits(from: help, in: doc.positions))
        doc.apply(edits, actionName: "Quick Fix")
        #expect(doc.text == "sim.Crash old\nsim.Crash two\n")
        #expect(doc.undoManager.undoActionName == "Quick Fix")
        doc.undoManager.undo()
        #expect(doc.text == "sim.Crsh old\nsim.Crsh two\n")
        doc.undoManager.redo()
        #expect(doc.text == "sim.Crash old\nsim.Crash two\n")
    }

    @Test func twoChangesAreTwoUndoSteps() {
        let doc = makeDoc("a\n")
        doc.replaceText(with: "ab\n", actionName: "One")
        doc.replaceText(with: "abc\n", actionName: "Two")
        doc.undoManager.undo()
        #expect(doc.text == "ab\n")
        doc.undoManager.undo()
        #expect(doc.text == "a\n")
    }
}

extension CheckReport.Help {
    /// A help with edits (line, col, endLine, endCol, new), decoded from JSON.
    static func test(edits: [(Int, Int, Int, Int, String)]) -> CheckReport.Help {
        let items = edits.map { #"{"line":\#($0.0),"col":\#($0.1),"end":{"line":\#($0.2),"col":\#($0.3)},"new":"\#($0.4)"}"# }
        let json = #"{"text":"fix","edits":[\#(items.joined(separator: ","))]}"#
        return try! JSONDecoder().decode(CheckReport.Help.self, from: Data(json.utf8))
    }
}
