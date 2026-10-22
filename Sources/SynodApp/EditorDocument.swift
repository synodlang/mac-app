import AppKit
import Foundation
import Observation
import SynodCore

/// A diagnostic span in a buffer, in UTF-16.
struct EditorMark: Equatable {
    enum Kind: Equatable { case error, warning, label }
    var range: NSRange
    var kind: Kind
    var message: String
    var hint: String?
    /// The diagnostic a primary mark comes from (its helps are the quick fixes); nil for a label.
    var diagnostic: CheckReport.Diagnostic?

    var tooltip: String {
        var s = message
        if let hint, !hint.isEmpty { s += "\n" + hint }
        return s
    }
}

/// A suggested edit of the compiler (`help[].edits`), applied only when the user picks it.
struct EditorFix: Equatable, Identifiable {
    var file: String
    var origin: WorkspaceModel.Origin
    var text: String
    var help: CheckReport.Help
    var id: String { "\(origin.rawValue):\(file):\(text)" }
}

/// Pure helpers of the editor, kept apart so they can be tested without a window.
enum EditorLogic {
    /// The smallest single replacement that turns `old` into `new` (nil when equal), found by
    /// trimming the common prefix and suffix; never splits a surrogate pair.
    static func minimalEdit(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        if old == new { return nil }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var p = 0
        let limit = min(a.count, b.count)
        while p < limit && a[p] == b[p] { p += 1 }
        if p > 0 && UTF16.isLeadSurrogate(a[p - 1]) { p -= 1 }
        var s = 0
        while s < limit - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if s > 0 && UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
        let range = NSRange(location: p, length: a.count - p - s)
        let replacement = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        return (range, replacement)
    }

    /// The marks of one file's diagnostics (and of secondary labels that sit in the same file).
    /// An empty span marks one character.
    static func marks(for file: String, diagnostics: [CheckReport.Diagnostic], positions: TextPositions) -> [EditorMark] {
        var marks: [EditorMark] = []
        let text = positions.utf16Length
        for d in diagnostics {
            if d.file == file, var r = positions.utf16Range(from: SourcePosition(line: d.line, col: d.col), to: d.end) {
                if r.length == 0 {
                    if r.location < text { r.length = 1 } else if r.location > 0 { r.location -= 1; r.length = 1 }
                }
                if r.length > 0 {
                    marks.append(EditorMark(range: r, kind: d.isError ? .error : .warning,
                                            message: d.message, hint: d.hint, diagnostic: d))
                }
            }
            for l in d.labels where l.file == file {
                if let r = positions.utf16Range(from: SourcePosition(line: l.line, col: l.col), to: l.end), r.length > 0 {
                    marks.append(EditorMark(range: r, kind: .label, message: l.text, hint: nil, diagnostic: nil))
                }
            }
        }
        return marks
    }

    /// Moves marks with an edit: marks after it shift, marks it overlaps are dropped.
    static func shift(_ marks: [EditorMark], replacing range: NSRange, withLength n: Int) -> [EditorMark] {
        let a = range.location
        let b = NSMaxRange(range)
        let delta = n - range.length
        var out: [EditorMark] = []
        for var m in marks {
            let s = m.range.location
            let e = NSMaxRange(m.range)
            if e <= a { out.append(m) } else if s >= b { m.range.location += delta; out.append(m) }
        }
        return out
    }

    /// The fixes whose diagnostic span covers `offset` (touching its end counts), the first with
    /// edits first.
    static func fixes(in marks: [EditorMark], at offset: Int, file: String, origin: WorkspaceModel.Origin) -> [EditorFix] {
        var seen = Set<String>()
        var out: [EditorFix] = []
        for m in marks where m.kind != .label {
            guard let d = m.diagnostic, offset >= m.range.location, offset <= NSMaxRange(m.range) else { continue }
            for h in d.help where !h.edits.isEmpty {
                let fix = EditorFix(file: file, origin: origin, text: h.text, help: h)
                if seen.insert(fix.id).inserted { out.append(fix) }
            }
        }
        return out
    }
}

/// One open file: its text (a text storage, so a text view can show it), undo history, saved
/// text, tokens and diagnostics. Edits keep the token and mark ranges moving (decision 78).
@MainActor @Observable
final class EditorDocument: Identifiable {
    let file: String
    let origin: WorkspaceModel.Origin
    let url: URL
    private(set) var isReadOnly: Bool

    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored let undoManager = UndoManager()

    /// Counts every change of the characters.
    private(set) var version = 0
    private(set) var savedText: String
    private(set) var isDirty = false
    private(set) var tokens: [PositionedToken] = []
    private(set) var marks: [EditorMark] = []
    /// The version the tokens and marks were computed for; nil before the first check.
    private(set) var checkedVersion: Int?
    /// The disk text, when the file changed outside while the buffer has edits.
    var conflict: String?
    /// What `synod fmt` printed when it refused the saved file.
    var formatOutput: String?
    /// A one-line status for the pane (saving, formatted, ...).
    var status: String?

    var selection = NSRange(location: 0, length: 0)
    /// Set by the view: moves the text view's selection.
    @ObservationIgnored var selectionSink: ((NSRange) -> Void)?
    /// Called after every character edit (the model schedules its check).
    @ObservationIgnored var onEdit: (() -> Void)?
    /// Called when the look should be redone (tokens or marks changed).
    @ObservationIgnored var onHighlightNeeded: (() -> Void)?

    @ObservationIgnored private let storageDelegate = StorageDelegate()
    @ObservationIgnored private var positionsCache: (version: Int, positions: TextPositions)?
    @ObservationIgnored private var highlightPending = false

    var id: String { "\(origin.rawValue):\(file)" }

    /// `groupsUndoByEvent` is true in the app (a text view's typing groups by run-loop event); headless
    /// runs and tests have no events and close every change's group themselves.
    init(file: String, origin: WorkspaceModel.Origin, url: URL, text: String, isReadOnly: Bool, groupsUndoByEvent: Bool = true) {
        self.file = file
        self.origin = origin
        self.url = url
        self.isReadOnly = isReadOnly
        savedText = text
        undoManager.groupsByEvent = groupsUndoByEvent
        storageDelegate.doc = self
        storage.delegate = storageDelegate
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.setAttributes(EditorHighlighter.baseAttributes, range: NSRange(location: 0, length: storage.length))
        version = 0
        isDirty = false
    }

    var text: String { storage.string }

    var positions: TextPositions {
        if let c = positionsCache, c.version == version { return c.positions }
        let p = TextPositions(text)
        positionsCache = (version, p)
        return p
    }

    /// The tokens and marks are for the current text.
    var isChecked: Bool { checkedVersion == version }

    // MARK: Edits

    private final class StorageDelegate: NSObject, NSTextStorageDelegate {
        weak var doc: EditorDocument?
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { doc?.didEdit(editedRange: editedRange, delta: delta) }
        }
    }

    private func didEdit(editedRange: NSRange, delta: Int) {
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        tokens = TokenShifter.shift(tokens, replacing: old, withLength: editedRange.length)
        marks = EditorLogic.shift(marks, replacing: old, withLength: editedRange.length)
        // Inserted text starts plain; the next highlight colors it from the shifted tokens.
        storage.setAttributes(EditorHighlighter.baseAttributes, range: editedRange)
        version += 1
        isDirty = storage.string != savedText
        if isDirty { status = nil }
        scheduleHighlight()
        onEdit?()
    }

    /// Replaces a range by a string and registers its inverse. Must run inside `perform`.
    func replace(_ range: NSRange, with s: String) {
        let old = (storage.string as NSString).substring(with: range)
        let newLength = (s as NSString).length
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.replace(NSRange(location: range.location, length: newLength), with: old) }
        }
        storage.replaceCharacters(in: range, with: s)
    }

    /// One undo group of edits, named for the Edit menu.
    func perform(actionName: String, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Applies `edits` (descending, non-overlapping) as one undoable change.
    func apply(_ edits: [TextEdit], actionName: String) {
        perform(actionName: actionName) {
            for e in edits { replace(e.range, with: e.replacement) }
        }
    }

    /// Replaces the whole text by `new` as one undoable change that touches only what differs.
    @discardableResult
    func replaceText(with new: String, actionName: String) -> Bool {
        guard let (range, replacement) = EditorLogic.minimalEdit(from: text, to: new) else { return false }
        perform(actionName: actionName) { replace(range, with: replacement) }
        return true
    }

    /// Takes the disk text as the buffer's text without undo history (a clean reload).
    func reload(from disk: String) {
        if let (range, replacement) = EditorLogic.minimalEdit(from: text, to: disk) {
            storage.replaceCharacters(in: range, with: replacement)
        }
        undoManager.removeAllActions()
        markSaved(disk)
        conflict = nil
        formatOutput = nil
    }

    func markSaved(_ text: String) {
        savedText = text
        isDirty = storage.string != text
    }

    func setReadOnly(_ value: Bool) { isReadOnly = value }

    func requestSelection(_ range: NSRange) {
        selection = range
        selectionSink?(range)
    }

    /// The position of `offset` as line and column, for restoring a selection after a reformat.
    func linePosition(ofOffset offset: Int) -> SourcePosition? { positions.position(utf16Offset: offset) }

    // MARK: Tokens and marks

    /// Takes the result of a check made for `version`. Ignored when the text moved on.
    @discardableResult
    func setCheck(tokens fileTokens: FileTokens?, diagnostics: [CheckReport.Diagnostic], forVersion v: Int) -> Bool {
        guard v == version else { return false }
        if let fileTokens { tokens = PositionedToken.place(fileTokens.tokens, in: positions) }
        marks = EditorLogic.marks(for: file, diagnostics: diagnostics, positions: positions)
        checkedVersion = v
        scheduleHighlight()
        return true
    }

    func clearCheck() {
        tokens = []
        marks = []
        checkedVersion = nil
        scheduleHighlight()
    }

    /// The token at a UTF-16 offset (the one that covers it).
    func token(atOffset offset: Int) -> PositionedToken? {
        tokens.first { offset >= $0.range.location && offset < NSMaxRange($0.range) }
    }

    func fixes(atOffset offset: Int) -> [EditorFix] {
        guard isChecked else { return [] }
        return EditorLogic.fixes(in: marks, at: offset, file: file, origin: origin)
    }

    // MARK: Look

    func scheduleHighlight() {
        guard !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.highlightPending = false
                self.applyHighlight()
            }
        }
    }

    /// Colors the buffer from the current tokens and marks. Returns how many tokens were colored.
    @discardableResult
    func applyHighlight() -> Int {
        let n = EditorHighlighter.apply(tokens: tokens, marks: marks, to: storage)
        onHighlightNeeded?()
        return n
    }
}
