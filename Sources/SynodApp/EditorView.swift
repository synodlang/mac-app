import AppKit
import SwiftUI
import SynodCore

/// The text view: ⌘-click goes to a definition, paste is always plain text.
final class SynodTextView: NSTextView {
    var onCommandClick: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            let p = convert(event.locationInWindow, from: nil)
            var idx = characterIndexForInsertion(at: p)
            // The insertion point sits between characters; a click on the left half of a word's
            // last character gives the next index, so look at the character under the pointer.
            if let window {
                let screen = firstRect(forCharacterRange: NSRange(location: idx, length: 0), actualRange: nil)
                let inView = convert(window.convertFromScreen(screen).origin, from: nil)
                if p.x < inView.x, idx > 0 { idx -= 1 }
            }
            if onCommandClick?(idx) == true { return }
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// Line numbers, error and warning marks and the lightbulb of a quick fix.
final class EditorGutter: NSRulerView {
    weak var document: EditorDocument?
    var onFixes: (([EditorFix], NSPoint) -> Void)?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 46
        clientView = scrollView.documentView
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private struct LineInfo {
        var number: Int
        var y: CGFloat
        var height: CGFloat
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.textLayoutManager,
              let cs = tv.textContentStorage, let doc = document else { return }
        EditorPalette.paper.color.blended(withFraction: 0.06, of: EditorPalette.ink.color)?.setFill()
        NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()
        let visible = tv.visibleRect
        let inset = tv.textContainerOrigin.y
        let positions = doc.positions
        var severity: [Int: EditorMark.Kind] = [:]
        var bulbs = Set<Int>()
        for m in doc.marks where m.kind != .label {
            guard let line = positions.position(utf16Offset: m.range.location)?.line else { continue }
            if severity[line] != .error { severity[line] = m.kind }
            if doc.isChecked, m.diagnostic?.help.contains(where: { !$0.edits.isEmpty }) == true { bulbs.insert(line) }
        }
        let start = lm.textViewportLayoutController.viewportRange?.location ?? cs.documentRange.location
        lm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { frag in
            let frame = frag.layoutFragmentFrame
            let y = frame.minY + inset
            if y > visible.maxY { return false }
            guard let first = frag.textLineFragments.first else { return true }
            let offset = cs.offset(from: cs.documentRange.location, to: frag.rangeInElement.location)
            guard let line = positions.position(utf16Offset: offset)?.line else { return true }
            let top = self.convert(NSPoint(x: 0, y: y), from: tv).y
            let lineHeight = first.typographicBounds.height
            let label = NSAttributedString(string: "\(line)", attributes: [
                .font: self.numberFont, .foregroundColor: EditorPalette.quiet.color])
            let size = label.size()
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: top + (lineHeight - size.height) / 2))
            if doc.lineHighlight == line {
                EditorPalette.critical.color.setFill()
                NSRect(x: 0, y: top, width: 3, height: lineHeight).fill()
            }
            if let kind = severity[line] {
                let color = kind == .error ? EditorPalette.critical.color : EditorPalette.warning.color
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: top + lineHeight / 2 - 3, width: 6, height: 6)).fill()
            }
            if bulbs.contains(line),
               let img = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Quick fix") {
                let tint = img.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
                EditorPalette.accent.color.set()
                tint?.draw(in: NSRect(x: 14, y: top + lineHeight / 2 - 6, width: 11, height: 12))
            }
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = clientView as? NSTextView, let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        let inTV = tv.convert(event.locationInWindow, from: nil)
        let idx = tv.characterIndexForInsertion(at: NSPoint(x: tv.textContainerOrigin.x + 2, y: inTV.y))
        guard let line = doc.positions.position(utf16Offset: idx)?.line, let lineRange = doc.positions.utf16LineRange(line) else { return }
        var fixes: [EditorFix] = []
        var seen = Set<String>()
        for m in doc.marks where m.kind != .label && NSIntersectionRange(m.range, lineRange).length > 0 {
            for f in EditorLogic.fixes(in: [m], at: m.range.location, file: doc.file, origin: doc.origin) where doc.isChecked && seen.insert(f.id).inserted {
                fixes.append(f)
            }
        }
        if fixes.isEmpty {
            tv.setSelectedRange(lineRange)
        } else {
            onFixes?(fixes, p)
        }
    }
}

/// A text view on TextKit 2 over an `EditorDocument`: monospaced, colored by tokens, underlined by
/// diagnostics, with a gutter.
struct EditorTextView: NSViewRepresentable {
    let model: EditorModel
    let document: EditorDocument

    func makeCoordinator() -> Coordinator { Coordinator(model: model, document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.build(model: model, document: document, coordinator: context.coordinator)
    }

    /// The scroll view with text view and gutter; also what the headless render check hosts.
    static func build(model: EditorModel, document: EditorDocument, coordinator: Coordinator) -> NSScrollView {
        let tv = SynodTextView(usingTextLayoutManager: true)
        tv.textContentStorage?.textStorage = document.storage
        tv.delegate = coordinator
        tv.allowsUndo = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.isEditable = !document.isReadOnly
        tv.isSelectable = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = EditorHighlighter.font(semibold: false)
        tv.typingAttributes = EditorHighlighter.baseAttributes
        tv.drawsBackground = true
        tv.backgroundColor = EditorPalette.paper.color
        tv.insertionPointColor = EditorPalette.accent.color
        tv.selectedTextAttributes = [.backgroundColor: EditorPalette.accent.color.withAlphaComponent(0.28)]
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.setAccessibilityLabel("Synod source: \(document.file)")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorPalette.paper.color
        scroll.documentView = tv
        let gutter = EditorGutter(scrollView: scroll)
        gutter.document = document
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true

        coordinator.attach(textView: tv, gutter: gutter, scroll: scroll)
        document.scheduleHighlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SynodTextView else { return }
        let editable = !document.isReadOnly
        if tv.isEditable != editable { tv.isEditable = editable }
        context.coordinator.handleReveal(model.reveal)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: EditorModel
        let document: EditorDocument
        private weak var textView: SynodTextView?
        private weak var gutter: EditorGutter?
        private var lastReveal = 0
        private var scrollObserver: NSObjectProtocol?

        init(model: EditorModel, document: EditorDocument) {
            self.model = model
            self.document = document
        }

        func attach(textView tv: SynodTextView, gutter: EditorGutter, scroll: NSScrollView) {
            textView = tv
            self.gutter = gutter
            tv.onCommandClick = { [weak self] idx in self?.goToDefinition(idx) ?? false }
            gutter.onFixes = { [weak self] fixes, point in
                guard let self, let gutter = self.gutter else { return }
                self.presentMenu(fixes, at: point, in: gutter)
            }
            document.selectionSink = { [weak tv] range in
                guard let tv else { return }
                let len = tv.textStorage?.length ?? 0
                tv.setSelectedRange(NSRange(location: min(range.location, len), length: min(range.length, max(0, len - range.location))))
                tv.scrollRangeToVisible(tv.selectedRange())
            }
            document.onHighlightNeeded = { [weak gutter] in gutter?.needsDisplay = true }
            model.presentFixes = { [weak self] fixes in self?.presentCaretFixes(fixes) }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak gutter] _ in MainActor.assumeIsolated { gutter?.needsDisplay = true } }
            tv.setSelectedRange(document.selection)
        }

        func detach() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            document.selectionSink = nil
            document.onHighlightNeeded = nil
            model.presentFixes = nil
        }

        // MARK: Delegate

        func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let tv = textView { document.selection = tv.selectedRange() }
        }

        // MARK: Navigation

        private func goToDefinition(_ idx: Int) -> Bool {
            do { return try model.goToDefinition(in: document, atOffset: idx) } catch {
                model.lastError = error.localizedDescription
                return true
            }
        }

        func handleReveal(_ reveal: EditorModel.Reveal?) {
            guard let r = reveal, r.serial != lastReveal, r.file == document.file, r.origin == document.origin,
                  let tv = textView else { return }
            lastReveal = r.serial
            let positions = document.positions
            guard let start = positions.utf16Offset(line: r.line, col: r.col) else { return }
            var length = 0
            if let el = r.endLine, let ec = r.endCol, let end = positions.utf16Offset(line: el, col: ec) {
                length = max(end - start, 0)
                if length == 0 { length = start < positions.utf16Length ? 1 : 0 }
            } else if let t = document.token(atOffset: start), t.range.location == start {
                length = t.range.length
            }
            let range = NSRange(location: start, length: length)
            DispatchQueue.main.async { [weak self, weak tv] in
                MainActor.assumeIsolated {
                    guard let tv else { return }
                    tv.window?.makeFirstResponder(tv)
                    tv.setSelectedRange(range)
                    tv.scrollRangeToVisible(range)
                    tv.showFindIndicator(for: range)
                    _ = self
                }
            }
        }

        // MARK: Quick fixes

        private func presentCaretFixes(_ fixes: [EditorFix]) {
            guard let tv = textView else { return }
            let screen = tv.firstRect(forCharacterRange: NSRange(location: document.selection.location, length: 0), actualRange: nil)
            let inView: NSPoint
            if let window = tv.window {
                let o = tv.convert(window.convertFromScreen(screen).origin, from: nil)
                inView = NSPoint(x: o.x, y: o.y + screen.height)
            } else {
                inView = .zero
            }
            presentMenu(fixes, at: inView, in: tv)
        }

        private func presentMenu(_ fixes: [EditorFix], at point: NSPoint, in view: NSView) {
            let menu = NSMenu(title: "Quick Fix")
            if fixes.isEmpty {
                let item = NSMenuItem(title: "No quick fixes here", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for fix in fixes {
                let item = NSMenuItem(title: fix.text, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = fix
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: point, in: view)
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let fix = sender.representedObject as? EditorFix else { return }
            do {
                try model.apply(fix)
                model.lastError = nil
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

/// The editor pane: a header, banners for read-only files, outside changes and `fmt` output,
/// and the text.
struct EditorPane: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let editor = model.editor
        VStack(spacing: 0) {
            if let doc = editor.current {
                EditorHeader(model: model, doc: doc)
                EditorBanners(model: model, doc: doc)
                Divider()
                EditorTextView(model: editor, document: doc)
                    .id(doc.id)
            } else {
                ContentUnavailableView("No file", systemImage: "doc.text", description: Text("Select a program, a package or a problem."))
            }
        }
        .background(Color(nsColor: EditorPalette.paper.color))
    }
}

struct EditorHeader: View {
    @Bindable var model: WorkspaceModel
    let doc: EditorDocument

    var body: some View {
        let editor = model.editor
        HStack(spacing: 8) {
            Picker("File", selection: Binding(get: { doc.id }, set: { id in
                if let f = editor.siblingFiles(of: doc).first(where: { EditorModel.key($0, doc.origin) == id }) {
                    try? editor.show(file: f, origin: doc.origin)
                }
            })) {
                ForEach(editor.siblingFiles(of: doc), id: \.self) { Text($0).tag(EditorModel.key($0, doc.origin)) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            if doc.isDirty {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange).help("Unsaved changes")
            }
            if doc.isReadOnly { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Read-only") }
            if let status = doc.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if editor.isChecking { ProgressView().controlSize(.mini) }
            Spacer()
            let errors = doc.marks.filter { $0.kind == .error }.count
            let warnings = doc.marks.filter { $0.kind == .warning }.count
            if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption) }
            if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            Button("Save") { editor.saveCurrent() }
                .disabled(doc.isReadOnly || (!doc.isDirty))
                .help("Save and format (⌘S)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}

struct EditorBanners: View {
    @Bindable var model: WorkspaceModel
    let doc: EditorDocument

    var body: some View {
        let editor = model.editor
        VStack(spacing: 0) {
            if doc.isReadOnly {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text(doc.file.hasPrefix("vendor/") ? "Vendored code is read-only." : "Bundled examples are read-only.")
                        .font(.callout)
                    Spacer()
                    if doc.origin == .examples || model.isReadOnly {
                        Button("Copy Examples to Folder…") { model.copyExamples() }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
            }
            if doc.conflict != nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("This file changed on disk. Reload it, or keep your unsaved text?").font(.callout)
                    Spacer()
                    Button("Reload") { editor.reloadFromDisk(doc) }
                    Button("Keep mine") { editor.keepMine(doc) }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.14))
            }
            if let out = doc.formatOutput, !out.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.orange)
                    Text("synod fmt could not format this file: \(out)").font(.callout.monospaced()).lineLimit(4)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.14))
            }
            if let err = editor.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).font(.callout).lineLimit(3)
                    Spacer()
                    Button { editor.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.red.opacity(0.12))
            }
        }
    }
}
