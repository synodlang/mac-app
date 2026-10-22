import SwiftUI
import SynodCore

/// The prompt bar (⌘K): a request field below the editor, Claude's progress, and the banner that
/// follows a request ("Claude changed N files": Show changes, Save All, Revert).
struct PromptBar: View {
    @Bindable var model: WorkspaceModel
    @Environment(AppEnvironment.self) private var env
    @FocusState private var focused: Bool

    var body: some View {
        let claude = model.claude
        VStack(alignment: .leading, spacing: 6) {
            if claude.hasBanner { ChangesBanner(model: model) }
            if let err = claude.errorText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(err).font(.callout).textSelection(.enabled).lineLimit(4)
                    Spacer(minLength: 0)
                }
            } else if let problem = env.promptBarProblem, !claude.isRunning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(problem).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                }
            }
            if !claude.progress.isEmpty || claude.isRunning {
                ProgressLines(lines: claude.progress, running: claude.isRunning)
            }
            if let text = claude.finalText, !claude.isRunning, !text.isEmpty {
                Text(text).font(.callout).textSelection(.enabled).lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField(model.isReadOnly ? "The prompt bar is off on the bundled examples" : "Ask Claude to write or change Synod",
                          text: Binding(get: { claude.draft }, set: { claude.draft = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(claude.isRunning || model.isReadOnly)
                    .onSubmit { submit() }
                Menu {
                    Button("Explain this run") { Task { await claude.explainRun() } }
                        .disabled(model.loaded == nil || claude.isRunning || model.isReadOnly)
                    Divider()
                    Button("New conversation") { claude.newConversation() }
                        .disabled(claude.isRunning || claude.sessionID == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Presets and conversation")
                if claude.isRunning {
                    Button { claude.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop Claude (interrupts the request)")
                } else {
                    Button { submit() } label: { Label("Send", systemImage: "arrow.up.circle.fill") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.title3)
                        .disabled(claude.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isReadOnly)
                        .help("Send (⏎)")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .onChange(of: claude.focusSerial) { _, _ in focused = true }
        .sheet(isPresented: Binding(get: { claude.pendingRequest != nil }, set: { if !$0 { claude.cancelPending() } })) {
            SaveAllSheet(claude: claude)
        }
    }

    private func submit() {
        let text = model.claude.draft
        Task { await model.claude.send(text) }
    }
}

/// The last progress lines of a request, newest at the bottom.
struct ProgressLines: View {
    let lines: [String]
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Claude is working").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Claude changed N files", with Show changes, Save All (while a buffer is unsaved) and Revert.
struct ChangesBanner: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let claude = model.claude
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Claude changed \(claude.changed.count) file\(claude.changed.count == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
            if claude.unsavedLeft { Text("(unsaved)").font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Menu("Show changes") {
                ForEach(claude.changed, id: \.self) { f in
                    Button(f) { claude.showChange(f) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            if claude.unsavedLeft {
                Button("Save All") { Task { await claude.saveAll() } }
            }
            Button("Revert") { claude.revert() }
                .disabled(!claude.canRevert || claude.isRunning)
                .help(claude.canRevert ? "Restore the files as they were before the request" : "Revert is off: the workspace was too large to snapshot")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// "Save All and Send": the buffers are saved first so Claude starts from the files on disk.
struct SaveAllSheet: View {
    let claude: ClaudeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save all changes before sending?").font(.headline)
            Text("Claude reads and edits the files in this workspace, so unsaved changes are saved first (formatted, like Save):")
                .foregroundStyle(.secondary)
            Text(claude.pendingFiles.joined(separator: "\n")).font(.callout.monospaced())
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { claude.cancelPending() }
                    .keyboardShortcut(.cancelAction)
                Button("Save All and Send") { Task { await claude.confirmPending() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
