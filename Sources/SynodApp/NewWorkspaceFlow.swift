import AppKit
import SynodCore

/// File > New Workspace…: asks for a folder name and location, runs the bundled `synod new` and
/// returns the new workspace folder, or nil when cancelled or when it failed (an alert said why).
@MainActor
enum NewWorkspaceFlow {
    /// The panel result: where, and the options of the accessory view.
    struct Choice {
        var directory: URL
        var module: String
        var isLibrary: Bool
    }

    static func run(env: AppEnvironment = .shared) async -> URL? {
        guard let choice = askForChoice() else { return nil }
        return await create(choice, env: env, report: showError)
    }

    /// Creates the workspace and registers it so its window opens on the demo program.
    /// `report` receives the message of a failure.
    static func create(_ choice: Choice, env: AppEnvironment, report: (String) -> Void) async -> URL? {
        guard let runner = env.runner else {
            report("The synod compiler was not found. Set its path in Settings.")
            return nil
        }
        let request = NewWorkspace.Request(directory: choice.directory, module: choice.module, isLibrary: choice.isLibrary)
        do {
            let made = try await NewWorkspace.create(request, runner: runner)
            env.expectNewWorkspace(made)
            return made.root
        } catch {
            report(error.localizedDescription)
            return nil
        }
    }

    private static func askForChoice() -> Choice? {
        let panel = NSSavePanel()
        panel.title = "New Workspace"
        panel.message = "Name the new workspace folder. Synod creates it with a synod.mod and a demo program."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "my-system"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        let module = NSTextField()
        module.placeholderString = "example.com/<name>"
        module.translatesAutoresizingMaskIntoConstraints = false
        module.widthAnchor.constraint(equalToConstant: 260).isActive = true
        module.setAccessibilityLabel("Module path")
        let label = NSTextField(labelWithString: "Module path:")
        let library = NSButton(checkboxWithTitle: "Library (a package without a demo program)", target: nil, action: nil)
        let row = NSStackView(views: [label, module])
        row.spacing = 8
        let column = NSStackView(views: [row, library])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        panel.accessoryView = column

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Choice(directory: url, module: module.stringValue, isLibrary: library.state == .on)
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not create the workspace"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
