import Foundation
import Testing

@testable import SynodCore

private func complete(_ text: String, caret: Int? = nil) throws -> (CompletionRequest, [CompletionItem])? {
    Completion.complete(in: text, caret: caret ?? (text as NSString).length, report: try loadScope())
}

private func heads(_ text: String) throws -> [String] {
    try complete(text)?.1.map(\.head) ?? []
}

@Test func freeContextOffersOwnBareAndImportQualified() throws {
    let all = try heads("")
    // own package first (unexported included, receivers and events left out), then imports in order
    #expect(all == ["Commit", "Collect", "Helper", "net.Send", "net.Id", "time.Every", "r.Elect"])
    #expect(try heads("Co") == ["Commit", "Collect"])
    #expect(try heads("ne") == ["net.Send", "net.Id"])
    #expect(try heads("net.S") == ["net.Send"])
    #expect(try heads("  r.El") == ["r.Elect"])
}

@Test func caseInsensitiveMatchesRankAfterCaseSensitive() throws {
    #expect(try heads("c") == ["Commit", "Collect"])
    // 'Co' prefix of "Commit"/"Collect" vs lowercase 'co' matches both only case-insensitively
    let r = try complete("co")!
    #expect(r.1.map(\.head) == ["Commit", "Collect"])
    #expect(try heads("net.s") == ["net.Send"])
    #expect(try heads("time.e") == ["time.Every"])
}

@Test func qualifiedContextListsOnlyThatImport() throws {
    let (req, items) = try complete("  net.")!
    #expect(req.mode == .qualified("net"))
    #expect(req.partial == "net.")
    #expect(items.map(\.head) == ["net.Send", "net.Id"])
    // the qualifier is part of the head, so the whole run is replaced
    #expect(req.replaceRange == NSRange(location: 2, length: 4))
}

@Test func aliasIsTheQualifier() throws {
    let (req, items) = try complete("r.")!
    #expect(req.mode == .qualified("r"))
    #expect(items.map(\.head) == ["r.Elect"])
    // the module's own last segment is not a qualifier: `raft.` is a receiver
    #expect(try complete("raft.")!.0.mode == .receiver)
}

@Test func receiverContextOffersOwnReceiverPhrasesAndFields() throws {
    let (req, items) = try complete("  set x to (n.")!
    #expect(req.mode == .receiver)
    #expect(items.map(\.head) == ["Prepare", "secret", "State", "votes"])
    #expect(items.map(\.kind) == [.phrase, .phrase, .field, .field])
    let p = items[0]
    #expect(p.insertText == "Prepare round")
    #expect(p.placeholders == [NSRange(location: 8, length: 5)])
    #expect(try heads("n.St") == ["State"])
    #expect(try heads("n.pre") == ["Prepare"])
}

@Test func receiverQualifiedContextUsesExportedOnly() throws {
    let (req, items) = try complete("n.r.")!
    #expect(req.mode == .receiverQualified("r"))
    #expect(items.map(\.head) == ["Campaign", "Vote", "Term"])
    #expect(items[1].insertText == "Vote for")
    #expect(items[1].pattern == "[n: r.Node] r.Vote [for: node]")
    #expect(try heads("n.r.Ca") == ["Campaign"])
}

@Test func prefixNeedsASeparatorBefore() throws {
    #expect(try complete("x+Co") == nil)
    #expect(try complete("a-Co") == nil)
    #expect(try complete("(Co")?.1.count == 2)
    #expect(try complete("f {Co")?.1.count == 2)
    #expect(try complete("a,Co")?.1.count == 2)
    #expect(try complete("a..b") == nil)
    // caret in the middle of the text
    #expect(try complete("send Co now", caret: 7)?.1.count == 2)
}

@Test func insertTextAndPlaceholderRanges() throws {
    let r = try loadScope()
    let send = Completion.items(for: CompletionRequest(replaceRange: NSRange(location: 0, length: 4), partial: "net.", mode: .qualified("net")), in: r)[0]
    #expect(send.insertText == "net.Send m from a to b")
    let names = send.placeholders.map { (send.insertText as NSString).substring(with: $0) }
    #expect(names == ["m", "a", "b"])
    #expect(send.placeholders == [NSRange(location: 9, length: 1), NSRange(location: 16, length: 1), NSRange(location: 21, length: 1)])
    let ins = Completion.insertion(of: send, replacing: NSRange(location: 10, length: 2))
    #expect(ins.placeholders.first == NSRange(location: 19, length: 1))
    #expect(ins.caret == 10 + (send.insertText as NSString).length)
    #expect(send.detail == "gives —; node")
}

@Test func blockHolesAreNotInserted() throws {
    let r = try loadScope()
    let items = Completion.items(for: CompletionRequest(replaceRange: NSRange(location: 0, length: 3), partial: "Col", mode: .free), in: r)
    #expect(items.map(\.insertText) == ["Collect xs otherwise"])
    #expect(items[0].placeholders == [NSRange(location: 8, length: 2)])
    let every = Completion.items(for: CompletionRequest(replaceRange: NSRange(location: 0, length: 0), partial: "time.", mode: .qualified("time")), in: r)[0]
    #expect(every.insertText == "time.Every d")
}

@Test func atMostFiftyItems() throws {
    let phrases = (0..<80).map { i in
        "{\"pattern\":\"P\(i)\",\"items\":[{\"word\":\"P\(i)\"}],\"blocks\":[],\"receiver\":null,\"gives\":\"—\",\"contexts\":null,\"kind\":\"phrase\",\"native\":false,\"exported\":true,\"doc\":\"\",\"def\":null}"
    }.joined(separator: ",")
    let json = "{\"format\":\"synod-doc/1\",\"diagnostics\":[],\"scope\":{\"file\":\"a.synod\",\"package\":\"main\",\"imports\":[]},\"packages\":[{\"path\":\"m\",\"name\":\"main\",\"qualifier\":\"main\",\"title\":\"\",\"std\":false,\"activates\":false,\"phrases\":[\(phrases)],\"records\":[],\"node\":null}]}"
    let r = try DocReport.parse(Data(json.utf8))
    let (_, items) = Completion.complete(in: "P", caret: 1, report: r)!
    #expect(items.count == 50)
    #expect(items.first?.head == "P0")
}

@Test func noScopeMeansNoItems() throws {
    let r = try DocReport.parse(try Fixtures.data("doc/with-diagnostics.json"))
    #expect(Completion.complete(in: "Co", caret: 2, report: r)?.1.isEmpty == true)
}

// MARK: placeholders

@Test func placeholderCycleAndFill() {
    var set = PlaceholderSet(ranges: [NSRange(location: 9, length: 1), NSRange(location: 16, length: 1), NSRange(location: 21, length: 1)])
    let first = set.selectFirst()
    #expect(first == NSRange(location: 9, length: 1))
    // typing "msg" replaces the selected hole, then continues at its end
    let k1 = set.apply(replacing: NSRange(location: 9, length: 1), withLength: 1)
    let k2 = set.apply(replacing: NSRange(location: 10, length: 0), withLength: 2)
    #expect(k1 && k2)
    #expect(set.ranges == [NSRange(location: 9, length: 3), NSRange(location: 18, length: 1), NSRange(location: 23, length: 1)])
    #expect(set.unfilledRanges.count == 2)
    let n1 = set.next(), n2 = set.next(), n3 = set.next(), p1 = set.previous()
    #expect(n1 == NSRange(location: 18, length: 1))
    #expect(n2 == NSRange(location: 23, length: 1))
    #expect(n3 == NSRange(location: 9, length: 3))
    #expect(p1 == NSRange(location: 23, length: 1))
}

@Test func placeholderClears() {
    let base = PlaceholderSet(ranges: [NSRange(location: 5, length: 2), NSRange(location: 10, length: 2)])
    var outside = base
    let keptOutside = outside.apply(replacing: NSRange(location: 0, length: 0), withLength: 1)
    #expect(!keptOutside)
    #expect(outside.isEmpty)
    var straddle = base
    let keptStraddle = straddle.apply(replacing: NSRange(location: 6, length: 3), withLength: 0)
    let afterClear = straddle.next()
    #expect(!keptStraddle)
    #expect(straddle.isEmpty && afterClear == nil)
    var cleared = base
    cleared.clear()
    #expect(cleared.isEmpty && cleared.current == nil)
}
