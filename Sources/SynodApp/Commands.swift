import SwiftUI
import SynodCore

struct WorkspaceModelKey: FocusedValueKey { typealias Value = WorkspaceModel }

extension FocusedValues {
    var workspaceModel: WorkspaceModel? {
        get { self[WorkspaceModelKey.self] }
        set { self[WorkspaceModelKey.self] = newValue }
    }
}

/// Opens a folder chosen in a panel as a workspace window.
@MainActor
func chooseWorkspace() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a Synod workspace (a folder with synod.mod)."
    return panel.runModal() == .OK ? panel.url : nil
}

struct AppCommands: Commands {
    @FocusedValue(\.workspaceModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Workspace…") {
                if let url = chooseWorkspace() { openWindow(value: url) }
            }
            .keyboardShortcut("o")
            Button("Welcome") { openWindow(id: "welcome") }
            Divider()
            Button("Copy Examples to Folder…") { model?.copyExamples() }
                .disabled(model == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.editor.saveCurrent() }
                .keyboardShortcut("s")
                .disabled(model?.editor.current.map { $0.isReadOnly } ?? true)
        }
        CommandMenu("Editor") {
            Button("Quick Fix…") { model?.editor.quickFix() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(model?.editor.current == nil)
            Button("Go to Definition") { model?.editor.goToDefinitionAtCaret() }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(model?.editor.current == nil)
            Divider()
            Button(model?.editorVisible == false ? "Show Editor" : "Hide Editor") { model?.editorVisible.toggle() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandMenu("Run") {
            Button("Run") { model?.run(.manual) }
                .keyboardShortcut("r")
                .disabled(model?.activeProgram == nil)
            Button("Play or Pause") { model?.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model?.loaded == nil)
            Button("Previous Fact") { model?.stepFact(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model?.loaded == nil)
            Button("Next Fact") { model?.stepFact(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model?.loaded == nil)
            Divider()
            Button("Export Video…") { model?.showExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.loaded == nil)
        }
    }
}
