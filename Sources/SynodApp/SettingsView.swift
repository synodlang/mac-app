import AppKit
import SwiftUI
import SynodCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDisclosure = false
    @State private var copied: String?
    private let hub = EditorMCPHub.shared

    var body: some View {
        @Bindable var env = env
        Form {
            Section("Compiler") {
                TextField("synod path", text: $env.synodPathOverride, prompt: Text("Bundled compiler"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("In use") { Text(env.tools?.synod.path ?? "not found").textSelection(.enabled).lineLimit(2) }
                if let v = env.version {
                    LabeledContent("Version") { Text("language \(v.language), compiler \(v.compiler)") }
                    if let note = v.completionNote {
                        Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                if let p = env.versionProblem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Claude") {
                Toggle("Enable the prompt bar (uses Claude Code)", isOn: Binding(
                    get: { env.promptBarEnabled },
                    set: { on in
                        if on { showDisclosure = true } else { env.promptBarEnabled = false }
                    }))
                TextField("claude path", text: $env.claudePath, prompt: Text(ClaudeLocator.detect()?.path ?? "~/.local/bin/claude"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("In use") {
                    if let url = env.claudeURL {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(url.path).textSelection(.enabled).lineLimit(2)
                            Text(env.claudeVersion ?? (env.claudeProbed ? "version unknown" : "checking the version…"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("not found").foregroundStyle(.secondary)
                    }
                }
                TextField("Model", text: $env.claudeModel, prompt: Text(ClaudeInvocation.defaultModel))
                    .textFieldStyle(.roundedBorder)
                Text("Empty uses Claude Code's own default model.").font(.caption).foregroundStyle(.secondary)
                if env.claudeURL == nil {
                    Text("Claude Code is not installed here. Install it from https://claude.com/product/claude-code, then set its path above.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle("Let Claude Code in Terminal use the editor", isOn: Binding(
                    get: { hub.externalEnabled },
                    set: { on in Task { await hub.setExternal(on) } }))
                Text("A Claude Code session you start in Terminal can read and edit the files open in a Synod window while this is on. It is off every time Synod starts and is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
                if hub.externalEnabled {
                    copyControls
                    Text("The copied line is valid until Synod quits or you press Disconnect in the window.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
                }
                if let e = hub.lastError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear {
            env.probeIfNeeded()
            env.probeClaudeIfNeeded()
        }
        .sheet(isPresented: $showDisclosure) {
            PromptBarDisclosure(
                enable: {
                    env.promptBarEnabled = true
                    showDisclosure = false
                },
                cancel: { showDisclosure = false })
        }
    }

    @ViewBuilder private var copyControls: some View {
        let windows = WorkspaceRegistry.models
        if windows.isEmpty {
            Button("Copy MCP config") {}.disabled(true)
            Text("Open a workspace window first: the line names its folder.").font(.caption).foregroundStyle(.secondary)
        } else if windows.count == 1 {
            Button("Copy MCP config") { copy(windows[0]) }
        } else {
            Menu("Copy MCP config for…") {
                ForEach(windows.indices, id: \.self) { i in
                    Button(windows[i].workspace.root.path) { copy(windows[i]) }
                }
            }
        }
    }

    private func copy(_ model: WorkspaceModel) {
        guard let line = hub.copyableCommand(for: model) else {
            copied = "The editor bridge was not found."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        copied = "Copied. Paste it into Terminal."
    }
}

/// What turning the prompt bar on means (decision 96).
struct PromptBarDisclosure: View {
    let enable: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enable the prompt bar?").font(.headline)
            Text("The prompt bar runs your own `claude` command (Claude Code) in the workspace folder.")
            Text("Your request, and the files Claude reads, go to Anthropic under your Claude Code account. Synod stores no key and never asks for your login: Claude Code keeps its own.")
            Text("Claude changes your files only through Synod's editor, so every change can be undone, and you can revert a whole request.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Enable", action: enable).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
