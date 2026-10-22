import AppKit
import Foundation
import Testing
import SynodCore
@testable import SynodApp

private let scopeJSON = """
{"format":"synod-doc/1","diagnostics":[],
 "scope":{"file":"a/a.synod","package":"main","imports":[{"path":"std/net","qualifier":"net"},{"path":"x/twopc","qualifier":"twopc"}]},
 "packages":[
  {"path":"x/a#main","name":"main","qualifier":"","title":"","std":false,"activates":false,"records":[],"node":null,
   "phrases":[
    {"pattern":"Begin [n: number]","items":[{"word":"Begin"},{"hole":"n","type":"number"}],"blocks":[],"receiver":null,"gives":"—","contexts":null,"kind":"phrase","native":false,"exported":true,"doc":"Begin a round","def":null}]},
  {"path":"std/net","name":"net","qualifier":"net","title":"the simulated network","std":true,"activates":false,"records":[],"node":null,
   "phrases":[
    {"pattern":"net.Send [m: msg] from [a: node] to [b: node]","items":[{"word":"net.Send"},{"hole":"m","type":"msg"},{"word":"from"},{"hole":"a","type":"node"},{"word":"to"},{"hole":"b","type":"node"}],"blocks":[],"receiver":null,"gives":"—","contexts":["node"],"kind":"phrase","native":true,"exported":true,"doc":"Send through the network","def":null},
    {"pattern":"net.Heal","items":[{"word":"net.Heal"}],"blocks":[],"receiver":null,"gives":"—","contexts":["main"],"kind":"phrase","native":true,"exported":true,"doc":"","def":null}]},
  {"path":"x/twopc","name":"twopc","qualifier":"twopc","title":"","std":false,"activates":false,"records":[],"node":null,
   "phrases":[
    {"pattern":"twopc.Coordinate [ps: list of twopc.Node] from [c: twopc.Node]","items":[{"word":"twopc.Coordinate"},{"hole":"ps","type":"list of twopc.Node"},{"word":"from"},{"hole":"c","type":"twopc.Node"}],"blocks":[],"receiver":null,"gives":"—","contexts":null,"kind":"phrase","native":false,"exported":true,"doc":"","def":null}]}
 ]}
"""

@MainActor
private func makeController(text: String, enabled: Bool = true) throws -> (CompletionController, EditorDocument, EditorModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-completion-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
    try "module example.com/t\nsynod 0.2\n".write(to: root.appendingPathComponent("synod.mod"), atomically: true, encoding: .utf8)
    try text.write(to: root.appendingPathComponent("a/a.synod"), atomically: true, encoding: .utf8)
    let editor = EditorModel(workspace: try Workspace.open(root), runner: { nil })
    editor.undoGroupsByEvent = false
    let controller = CompletionController(editor: editor, isEnabled: { enabled })
    controller.store(.scope(try DocReport.parse(Data(scopeJSON.utf8))), file: "a/a.synod")
    return (controller, try editor.open(file: "a/a.synod"), editor, root)
}

@MainActor @Suite struct CompletionControllerTests {
    @Test func autoOpenAfterADotOrTwoPrefixCharacters() {
        let open = { (s: String) in CompletionController.shouldAutoOpen(text: s, caret: (s as NSString).length) }
        #expect(open("  net."))
        #expect(open("  net.Se"))
        #expect(open("  ne"))
        #expect(open("set x to (lists.Si"))
        #expect(!open("  n"))
        #expect(!open("  "))
        #expect(!open("  ."))
        #expect(!open("  (."))
        #expect(!open("  1 plus "))
    }

    @Test func updateListsItemsAndTheArrowsMoveWithinThem() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n  net.")
        defer { try? FileManager.default.removeItem(at: root) }
        let caret = (doc.text as NSString).length
        #expect(c.update(in: doc, caret: caret))
        #expect(c.isOpen)
        #expect(c.items.map(\.head) == ["net.Send", "net.Heal"])
        #expect(c.selected == 0)
        c.move(1)
        #expect(c.selected == 1)
        c.move(1)
        #expect(c.selected == 1)      // stays at the end
        c.move(-5)
        #expect(c.selected == 0)
        c.dismiss()
        #expect(!c.isOpen && c.items.isEmpty)
    }

    @Test func anEmptyPrefixOpensOnlyWithControlSpace() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n  ")
        defer { try? FileManager.default.removeItem(at: root) }
        let caret = (doc.text as NSString).length
        #expect(!c.update(in: doc, caret: caret))
        #expect(c.update(in: doc, caret: caret, force: true))
        #expect(c.items.count == 4)    // own, then net, then twopc
        #expect(c.items.first?.head == "Begin")
    }

    @Test func acceptingInsertsPlaceholdersThatTabAndTypingFill() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n  net.Se")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(c.update(in: doc, caret: (doc.text as NSString).length))
        let ins = c.accept(into: doc)
        #expect(ins != nil)
        #expect(doc.text == "# package main\n  net.Send m from a to b")
        let ns = doc.text as NSString
        #expect(doc.placeholders.ranges.map { ns.substring(with: $0) } == ["m", "a", "b"])
        #expect(doc.selection == doc.placeholders.ranges[0])
        #expect(!c.isOpen)
        // Tab goes to a, typing fills it and the others keep their place.
        let aNext = doc.placeholders.next()
        let a = try #require(aNext)
        #expect(ns.substring(with: a) == "a")
        doc.perform(actionName: "Typing") { doc.replace(a, with: "peer") }
        #expect(doc.text == "# package main\n  net.Send m from peer to b")
        #expect(doc.placeholders.ranges.count == 3)
        let lastNext = doc.placeholders.next()
        let last = try #require(lastNext)
        #expect((doc.text as NSString).substring(with: last) == "b")
        // Shift-Tab goes back; an edit outside every range clears them.
        let back = doc.placeholders.previous()
        #expect(back != nil)
        doc.perform(actionName: "Typing") { doc.replace(NSRange(location: 0, length: 0), with: "x") }
        #expect(doc.placeholders.isEmpty)
    }

    @Test func aQualifiedHeadReplacesTheWholeRunAndAnItemWithoutHolesLeavesTheCaretAfterIt() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n  twopc.Co\n  net.He")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstLineEnd = ("# package main\n  twopc.Co" as NSString).length
        #expect(c.update(in: doc, caret: firstLineEnd))
        _ = c.accept(into: doc)
        #expect(doc.text.hasPrefix("# package main\n  twopc.Coordinate ps from c\n"))
        #expect(doc.placeholders.ranges.count == 2)
        doc.clearPlaceholders()
        let caret = (doc.text as NSString).length
        #expect(c.update(in: doc, caret: caret))
        let ins = c.accept(into: doc)
        #expect(doc.text.hasSuffix("\n  net.Heal"))
        #expect(ins?.placeholders.isEmpty == true)
        #expect(doc.selection == NSRange(location: (doc.text as NSString).length, length: 0))
    }

    @Test func offWhenTheCompilerLacksTheDocFormatOrTheBufferIsReadOnly() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n  net.", enabled: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!c.update(in: doc, caret: (doc.text as NSString).length))
        #expect(!c.isOpen)
        let (c2, doc2, _, root2) = try makeController(text: "# package main\n  net.")
        defer { try? FileManager.default.removeItem(at: root2) }
        doc2.setReadOnly(true)
        #expect(!c2.update(in: doc2, caret: (doc2.text as NSString).length))
    }

    @Test func aDiagnosticsOutcomeKeepsTheLastGoodScope() throws {
        let (c, _, _, root) = try makeController(text: "# package main\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try #require(c.scope(for: "a/a.synod"))
        c.store(.diagnostics(try DocReport.parse(Data(#"{"format":"synod-doc/1","diagnostics":[],"scope":null,"packages":[]}"#.utf8))), file: "a/a.synod")
        #expect(c.scope(for: "a/a.synod") == good)
    }

    @Test func aCheckWithAnErrorInTheFolderDoesNotRefresh() throws {
        let (c, doc, _, root) = try makeController(text: "# package main\n")
        defer { try? FileManager.default.removeItem(at: root) }
        c.refreshDelay = .milliseconds(1)
        let bad = try CheckReport.parse(Data(#"{"format":"synod-check/1","ok":false,"diagnostics":[{"file":"a/a.synod","line":1,"col":1,"end":{"line":1,"col":2},"severity":"error","code":"parse","message":"m"}],"files":[]}"#.utf8))
        c.checked(doc, report: bad)
        #expect(c.refreshCount == 0)
    }
}
