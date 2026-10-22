import AppKit
import SwiftUI

/// The open workspace models, so quitting can ask about every window's unsaved buffers.
@MainActor
enum WorkspaceRegistry {
    private final class Box { weak var model: WorkspaceModel?; init(_ m: WorkspaceModel) { model = m } }
    private static var boxes: [Box] = []

    static func add(_ model: WorkspaceModel) {
        boxes.removeAll { $0.model == nil }
        boxes.append(Box(model))
    }

    static func remove(_ model: WorkspaceModel) { boxes.removeAll { $0.model === model || $0.model == nil } }

    static var models: [WorkspaceModel] { boxes.compactMap(\.model) }
}

/// What the user answered to "Do you want to save the changes?".
enum UnsavedChoice: Equatable { case save, discard, cancel }

enum UnsavedText {
    /// The alert's message for these files.
    static func message(for files: [String]) -> (title: String, info: String) {
        if files.count == 1 {
            return ("Do you want to save the changes to \(files[0])?", "Your changes will be lost if you don't save them.")
        }
        let list = files.prefix(6).joined(separator: ", ") + (files.count > 6 ? ", …" : "")
        return ("Do you want to save the changes to \(files.count) files?", "\(list). Your changes will be lost if you don't save them.")
    }
}

extension WorkspaceModel {
    /// Shows the Save / Don't Save / Cancel alert (a sheet on `window` when there is one).
    static func askAboutUnsaved(files: [String], window: NSWindow?) async -> UnsavedChoice {
        let text = UnsavedText.message(for: files)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// True when it is fine to close or quit: nothing is unsaved, or the user saved or discarded it.
    /// Save writes every dirty buffer (formatted); a failed save keeps the window open.
    func resolveUnsaved(window: NSWindow? = nil,
                        ask: (([String]) async -> UnsavedChoice)? = nil) async -> Bool {
        let dirty = editor.dirtyDocuments
        guard !dirty.isEmpty else { return true }
        let files = dirty.map(\.file)
        let choice: UnsavedChoice
        if let ask { choice = await ask(files) } else { choice = await Self.askAboutUnsaved(files: files, window: window) }
        switch choice {
        case .cancel: return false
        case .discard: return true
        case .save:
            for doc in dirty {
                do {
                    try await editor.save(file: doc.file, origin: doc.origin)
                } catch {
                    editor.lastError = "Could not save \(doc.file): \(error.localizedDescription)"
                    return false
                }
            }
            return true
        }
    }
}

/// Stands in for a SwiftUI window's delegate: `windowShouldClose` asks about unsaved buffers,
/// and every other delegate message goes to the original delegate.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var original: NSWindowDelegate?
    weak var model: WorkspaceModel?
    private var closing = false

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        if let o = original, o.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))), o.windowShouldClose?(sender) == false {
            return false
        }
        guard let model, !model.editor.dirtyDocuments.isEmpty else { return true }
        Task { @MainActor [weak self, weak sender] in
            guard let self, let model = self.model, let sender else { return }
            if await model.resolveUnsaved(window: sender) {
                self.closing = true
                sender.close()
            }
        }
        return false
    }
}

/// Installs the close guard on the window that hosts the view and keeps its edited dot current.
struct UnsavedWindowGuard: NSViewRepresentable {
    let model: WorkspaceModel

    func makeCoordinator() -> WindowCloseGuard { WindowCloseGuard() }

    func makeNSView(context: Context) -> NSView {
        let v = GuardView()
        context.coordinator.model = model
        v.guardDelegate = context.coordinator
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        (nsView as? GuardView)?.install()
        nsView.window?.isDocumentEdited = !model.editor.dirtyDocuments.isEmpty
    }

    /// Puts the guard on the window as soon as the view has one, and again whenever SwiftUI
    /// replaces the window delegate (it does so after the first layout).
    final class GuardView: NSView {
        weak var guardDelegate: WindowCloseGuard?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            install()
            observation = window.observe(\.delegate, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.install() } }
            }
        }

        func install() {
            guard let window, let g = guardDelegate, window.delegate !== g else { return }
            g.original = window.delegate
            window.delegate = g
        }
    }
}

/// Quitting asks about each window's unsaved buffers first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// AppKit reads a folder on the command line (`Synod.app --args <folder>`) as a document to
    /// open, and then SwiftUI skips its launch window, so the router never runs. Reopening the
    /// app makes SwiftUI present the launch scene, which opens the folder (see `LaunchRouter`).
    func application(_ app: NSApplication, openFile f: String) -> Bool {
        DispatchQueue.main.async { NSWorkspace.shared.open(Bundle.main.bundleURL) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = WorkspaceRegistry.models.filter { !$0.editor.dirtyDocuments.isEmpty }
        guard !dirty.isEmpty else { return .terminateNow }
        Task { @MainActor in
            var ok = true
            for model in dirty {
                if await !model.resolveUnsaved(window: NSApp.windows.first { $0.isVisible && $0.isKeyWindow } ?? NSApp.windows.first(where: \.isVisible)) {
                    ok = false
                    break
                }
            }
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }
}
