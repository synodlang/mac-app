import Foundation

/// One completion row, built from a `synod doc --scope` document (decision 92).
public struct CompletionItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case phrase, field }

    public let kind: Kind
    /// The pattern as shown (`net.Send [m: msg] from [a: node] to [b: node]`).
    public let pattern: String
    /// The word the partial is matched against (`net.Send`; for a receiver item without its
    /// qualifier, `Send`).
    public let head: String
    /// The text that replaces the partial: the items joined by single spaces.
    public let insertText: String
    /// UTF-16 ranges of the holes inside `insertText`.
    public let placeholders: [NSRange]
    public let gives: String
    public let contexts: [String]?
    public let doc: String
    /// 0 for the file's own package, then 1... for imports in import order.
    public let packageIndex: Int
    public let sourceIndex: Int

    /// The detail line: `gives …; contexts`.
    public var detail: String {
        var s = "gives \(gives)"
        if let contexts, !contexts.isEmpty { s += "; " + contexts.joined(separator: ", ") }
        return s
    }
}

/// What the caret is in and what to put there.
public struct CompletionRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// No dot: own phrases and every import's exported non-receiver phrases.
        case free
        /// `q.` with `q` an import qualifier.
        case qualified(String)
        /// `x.` with `x` not a qualifier.
        case receiver
        /// `x.q.` with `q` an import qualifier.
        case receiverQualified(String)
    }

    /// The range the chosen item replaces: the partial after the last dot, or for `q.` the whole
    /// run (the item's head carries the qualifier).
    public let replaceRange: NSRange
    public let partial: String
    public let mode: Mode
}

/// An item applied to a buffer position.
public struct CompletionInsertion: Sendable, Equatable {
    public let range: NSRange
    public let text: String
    /// Hole ranges in buffer coordinates after the replacement.
    public let placeholders: [NSRange]
    /// The caret after the insertion when there is no hole.
    public let caret: Int
}

public enum Completion {
    public static let maxItems = 50

    /// Finds what is being typed before `caret` (a UTF-16 offset). Nil when the run of
    /// `[A-Za-z0-9.]` is not preceded by the start of the line, a space, `(`, `{` or `,`.
    /// With `force` (Ctrl-Space) an empty run is accepted after those characters too.
    public static func request(in text: String, caret: Int, qualifiers: Set<String>) -> CompletionRequest? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0, isPrefixChar(ns.character(at: start - 1)) { start -= 1 }
        if start > 0 {
            let before = ns.character(at: start - 1)
            guard before == 0x20 || before == 0x28 || before == 0x7B || before == 0x2C else { return nil }
        }
        let run = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let dot = run.lastIndex(of: ".") else {
            return CompletionRequest(replaceRange: NSRange(location: start, length: caret - start), partial: run, mode: .free)
        }
        let before = String(run[..<dot])
        let partial = String(run[run.index(after: dot)...])
        let partialLen = (partial as NSString).length
        let range = NSRange(location: caret - partialLen, length: partialLen)
        let parts = before.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let mode: CompletionRequest.Mode
        if parts.count == 1 {
            mode = qualifiers.contains(parts[0]) ? .qualified(parts[0]) : .receiver
        } else if let last = parts.last, qualifiers.contains(last) {
            mode = .receiverQualified(last)
        } else {
            mode = .receiver
        }
        if parts.contains(where: \.isEmpty) { return nil }
        // A qualified head is typed with its qualifier, so the whole run is the partial and is replaced.
        if case .qualified = mode {
            return CompletionRequest(replaceRange: NSRange(location: start, length: caret - start), partial: run, mode: mode)
        }
        return CompletionRequest(replaceRange: range, partial: partial, mode: mode)
    }

    private static func isPrefixChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2E
    }

    /// The import qualifiers of a scope document.
    public static func qualifiers(of report: DocReport) -> Set<String> {
        Set(report.scope?.imports.map(\.qualifier) ?? [])
    }

    /// The ranked items for `request`, at most 50.
    public static func items(for request: CompletionRequest, in report: DocReport) -> [CompletionItem] {
        guard report.scope != nil, let own = report.ownPackage else { return [] }
        let imports = report.importedPackages
        var candidates: [CompletionItem] = []
        switch request.mode {
        case .free:
            candidates += phraseItems(own.phrases, packageIndex: 0, receivers: false, exportedOnly: false, stripQualifier: nil)
            for (i, p) in imports.enumerated() {
                candidates += phraseItems(p.phrases, packageIndex: i + 1, receivers: false, exportedOnly: true, stripQualifier: nil)
            }
        case .qualified(let q):
            for (i, p) in imports.enumerated() where p.qualifier == q {
                candidates += phraseItems(p.phrases, packageIndex: i + 1, receivers: false, exportedOnly: true, stripQualifier: nil)
            }
        case .receiver:
            candidates += phraseItems(own.phrases, packageIndex: 0, receivers: true, exportedOnly: false, stripQualifier: nil)
            candidates += fieldItems(own.node, packageIndex: 0, exportedOnly: false)
        case .receiverQualified(let q):
            for (i, p) in imports.enumerated() where p.qualifier == q {
                candidates += phraseItems(p.phrases, packageIndex: i + 1, receivers: true, exportedOnly: true, stripQualifier: q)
                candidates += fieldItems(p.node, packageIndex: i + 1, exportedOnly: true)
            }
        }
        let partial = request.partial
        var ranked: [(rank: Int, item: CompletionItem)] = []
        for c in candidates {
            if c.head.hasPrefix(partial) {
                ranked.append((0, c))
            } else if c.head.lowercased().hasPrefix(partial.lowercased()) {
                ranked.append((1, c))
            }
        }
        ranked.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.item.packageIndex != $1.item.packageIndex { return $0.item.packageIndex < $1.item.packageIndex }
            return $0.item.sourceIndex < $1.item.sourceIndex
        }
        return Array(ranked.prefix(maxItems).map(\.item))
    }

    /// Convenience: request and items for a caret.
    public static func complete(in text: String, caret: Int, report: DocReport) -> (CompletionRequest, [CompletionItem])? {
        guard let req = request(in: text, caret: caret, qualifiers: qualifiers(of: report)) else { return nil }
        return (req, items(for: req, in: report))
    }

    /// Applies `item` in place of `request.replaceRange`.
    public static func insertion(of item: CompletionItem, replacing range: NSRange) -> CompletionInsertion {
        let shifted = item.placeholders.map { NSRange(location: $0.location + range.location, length: $0.length) }
        let len = (item.insertText as NSString).length
        return CompletionInsertion(range: range, text: item.insertText, placeholders: shifted, caret: range.location + len)
    }

    // MARK: building

    private static func phraseItems(_ phrases: [DocReport.Phrase], packageIndex: Int, receivers: Bool,
                                    exportedOnly: Bool, stripQualifier: String?) -> [CompletionItem] {
        var out: [CompletionItem] = []
        for (idx, p) in phrases.enumerated() {
            if p.isEvent { continue }
            if (p.receiver != nil) != receivers { continue }
            if exportedOnly && !p.exported { continue }
            var items = p.items
            if let r = p.receiver, let first = items.first, first.hole == r.name { items.removeFirst() }
            let blockHoles = Set(p.blocks.map(\.hole).filter { !$0.isEmpty })
            var text = ""
            var holes: [NSRange] = []
            var head: String?
            var firstWord = true
            for it in items {
                var piece: String
                if let w = it.word {
                    piece = w
                    if firstWord {
                        if let q = stripQualifier, w.hasPrefix(q + ".") { piece = String(w.dropFirst(q.count + 1)) }
                        head = piece
                    }
                    firstWord = false
                } else if let h = it.hole {
                    if blockHoles.contains(h) { continue }
                    piece = h
                } else { continue }
                if !text.isEmpty { text += " " }
                if it.word == nil {
                    holes.append(NSRange(location: (text as NSString).length, length: (piece as NSString).length))
                }
                text += piece
            }
            guard let head else { continue }
            out.append(CompletionItem(kind: .phrase, pattern: p.pattern, head: head, insertText: text, placeholders: holes,
                                      gives: p.gives, contexts: p.contexts, doc: p.doc,
                                      packageIndex: packageIndex, sourceIndex: idx))
        }
        return out
    }

    private static func fieldItems(_ node: DocReport.NodeType?, packageIndex: Int, exportedOnly: Bool) -> [CompletionItem] {
        guard let node else { return [] }
        var out: [CompletionItem] = []
        for (idx, f) in node.fields.enumerated() where !exportedOnly || f.exported {
            out.append(CompletionItem(kind: .field, pattern: f.name, head: f.name, insertText: f.name, placeholders: [],
                                      gives: f.type, contexts: nil, doc: node.doc,
                                      packageIndex: packageIndex, sourceIndex: 100_000 + idx))
        }
        return out
    }
}
