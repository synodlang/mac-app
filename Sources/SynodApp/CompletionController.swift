import AppKit
import Foundation
import Observation
import SwiftUI
import SynodCore

/// Phrase completion of one editor (decision 92): the scope of the shown file comes from
/// `synod doc --json --scope` (refreshed after a check, debounced, cached per file), the items and the
/// text to insert from `SynodCore.Completion`. This class holds the popup's state and the keyboard
/// model; `CompletionPopup` draws it and the text view's coordinator feeds it.
@MainActor @Observable
final class CompletionController {
    private(set) var items: [CompletionItem] = []
    private(set) var selected = 0
    private(set) var isOpen = false
    private(set) var request: CompletionRequest?
    /// How long the last `doc --scope` took, in milliseconds.
    private(set) var lastRefreshMs: Double?
    /// Counts finished scope refreshes (headless runs wait on it).
    private(set) var refreshCount = 0
    private(set) var lastError: String?
    /// How many refreshes ended with diagnostics (exit 1), keeping the previous scope.
    private(set) var diagnosticRefreshes = 0

    @ObservationIgnored private var scopes = ScopeCache()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var forced = false
    @ObservationIgnored let editor: EditorModel
    /// False when the compiler does not write `synod-doc/1`.
    @ObservationIgnored var isEnabled: () -> Bool
    @ObservationIgnored var refreshDelay: Duration = .milliseconds(150)

    init(editor: EditorModel, isEnabled: @escaping () -> Bool = { true }) {
        self.editor = editor
        self.isEnabled = isEnabled
    }

    func stop() {
        refreshTask?.cancel()
        dismiss()
    }

    // MARK: Scope

    func scope(for file: String) -> DocReport? { scopes.scope(for: file) }

    /// Takes a scope without running `synod doc` (tests).
    func store(_ outcome: DocRunner.Outcome, file: String) { scopes.apply(outcome, file: file) }

    /// Called after a check covered `doc`: refreshes the file's scope when its folder has no error.
    func checked(_ doc: EditorDocument, report: CheckReport) {
        guard doc.origin == .own, !doc.isReadOnly else { return }
        let folder = EditorModel.folder(of: doc.file)
        let hasError = report.diagnostics.contains { $0.isError && EditorModel.folder(of: $0.file) == folder }
        if !hasError { scheduleRefresh(for: doc) }
    }

    func scheduleRefresh(for doc: EditorDocument) {
        refreshTask?.cancel()
        let delay = refreshDelay
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            _ = await self?.refresh(file: doc.file)
        }
    }

    /// Runs `doc --scope` for `file` now, with the unsaved buffers as an overlay. On exit 1 the
    /// previous scope stays. Returns whether a scope is cached afterwards.
    @discardableResult
    func refresh(file: String) async -> Bool {
        guard isEnabled(), let runner = editor.runner() else { return false }
        var buffers: [String: String] = [:]
        for d in editor.documents.values where d.origin == .own && d.isDirty && !d.isReadOnly { buffers[d.file] = d.text }
        let docRunner = DocRunner(workspace: editor.workspace, runner: runner, cache: editor.cache)
        let start = ContinuousClock.now
        do {
            let outcome = try await docRunner.scope(file: file, buffers: buffers)
            let d = ContinuousClock.now - start
            lastRefreshMs = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            scopes.apply(outcome, file: file)
            if case .diagnostics = outcome { diagnosticRefreshes += 1 }
            lastError = nil
        } catch is CancellationError {
            return scopes.scope(for: file) != nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshCount += 1
        return scopes.scope(for: file) != nil
    }

    // MARK: Items

    /// Works out the items for `caret` of `doc`; opens the popup state when there are some. A ⌃Space
    /// (`force`) lists even with nothing typed.
    @discardableResult
    func update(in doc: EditorDocument, caret: Int, force: Bool = false) -> Bool {
        guard isEnabled(), !doc.isReadOnly, let report = scopes.scope(for: doc.file),
              let (req, found) = Completion.complete(in: doc.text, caret: caret, report: report) else {
            dismiss()
            return false
        }
        if force { forced = true }
        if req.mode == .free && req.partial.isEmpty && !forced { dismiss(); return false }
        if found.isEmpty { dismiss(); return false }
        if found != items { selected = 0 }
        items = found
        request = req
        isOpen = true
        return true
    }

    func dismiss() {
        guard isOpen || !items.isEmpty else { forced = false; return }
        isOpen = false
        items = []
        request = nil
        selected = 0
        forced = false
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selected = index
    }

    var selectedItem: CompletionItem? { items.indices.contains(selected) ? items[selected] : nil }

    /// Puts the selected item into `doc` in place of what was typed, as one undoable change. The holes
    /// become placeholders and the first is selected; an item without holes leaves the caret after it.
    @discardableResult
    func accept(into doc: EditorDocument) -> CompletionInsertion? {
        guard let item = selectedItem, let req = request else { return nil }
        let ins = Completion.insertion(of: item, replacing: req.replaceRange)
        dismiss()
        doc.clearPlaceholders()
        doc.perform(actionName: "Insert Completion") { doc.replace(ins.range, with: ins.text) }
        doc.placeholders = PlaceholderSet(ranges: ins.placeholders)
        if let first = doc.placeholders.selectFirst() {
            doc.requestSelection(first)
        } else {
            doc.requestSelection(NSRange(location: ins.caret, length: 0))
        }
        doc.onPlaceholdersChanged?()
        return ins
    }

    // MARK: Pure parts

    /// Whether typing just produced a place where the popup opens by itself: after `.` following a
    /// word, or after two prefix characters (⌃Space opens it anywhere).
    nonisolated static func shouldAutoOpen(text: String, caret: Int) -> Bool {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return false }
        var start = caret
        func isPrefix(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2E
        }
        while start > 0, isPrefix(ns.character(at: start - 1)) { start -= 1 }
        let run = ns.substring(with: NSRange(location: start, length: caret - start))
        if run.hasSuffix(".") {
            guard run.count >= 2 else { return false }
            let before = run.dropLast().last!
            return before.isLetter || before.isNumber
        }
        let segment = run.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? run
        return segment.count >= 2
    }
}

// MARK: - Popup

/// The completion list: a borderless child window below the text, so the text view keeps the focus.
@MainActor
final class CompletionPopup {
    private let controller: CompletionController
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private let rowHeight: CGFloat = 22
    private let stripHeight: CGFloat = 26
    private let width: CGFloat = 540

    var onAccept: (() -> Void)?

    init(controller: CompletionController) { self.controller = controller }

    /// Shows or moves the list, anchored below `anchor` (screen coordinates), or hides it.
    func sync(anchor: NSRect?, in window: NSWindow?) {
        guard controller.isOpen, let anchor, let window else { hide(); return }
        let rows = min(controller.items.count, 8)
        let height = CGFloat(rows) * rowHeight + stripHeight + 2
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 2)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - width)
            if origin.y < screen.minY { origin.y = anchor.maxY + 2 }
        }
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.hasShadow = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: CompletionListView(controller: controller) { [weak self] i in
                self?.controller.select(i)
                self?.onAccept?()
            })
            panel = p
        }
        panel?.setFrame(frame, display: true)
        if parent !== window || panel?.parent == nil {
            parent?.removeChildWindow(panel!)
            window.addChildWindow(panel!, ordered: .above)
            parent = window
        }
        panel?.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        parent = nil
    }
}

struct CompletionListView: View {
    let controller: CompletionController
    let accept: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.items.enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 8) {
                                Image(systemName: item.kind == .field ? "square.stack.3d.up" : "text.alignleft")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                                Text(item.pattern).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(i == controller.selected ? Color.accentColor.opacity(0.22) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { accept(i) }
                            .id(i)
                        }
                    }
                }
                .onChange(of: controller.selected) { _, new in proxy.scrollTo(new) }
            }
            Divider()
            Text(controller.selectedItem?.doc.isEmpty == false ? controller.selectedItem!.doc : " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
        }
        .background(Color(nsColor: EditorPalette.paper.color))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
    }
}
