import SwiftUI
import SynodCore

struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Synod").font(.system(size: 34, weight: .semibold))
                Text("Write a distributed system as a story, then watch it run.")
                    .foregroundStyle(.secondary)
            }
            if let p = env.versionProblem {
                BannerView(text: p, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 10) {
                Button("New Workspace…") {
                    Task { if let url = await NewWorkspaceFlow.run(env: env) { open(url) } }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                Button("Open Workspace…") { if let url = chooseWorkspace() { open(url) } }
                    .keyboardShortcut("o")
                Button("Open Examples") {
                    if let url = env.examplesURL { open(url) }
                }
                .disabled(env.examplesURL == nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.headline)
                if env.recents.isEmpty {
                    Text("No recent workspaces.").foregroundStyle(.secondary)
                } else {
                    ForEach(env.recents, id: \.self) { path in
                        Button {
                            open(URL(fileURLWithPath: path, isDirectory: true))
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.link)
                    }
                    Button("Clear Recents") { env.clearRecents() }.buttonStyle(.link).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 420, alignment: .topLeading)
        .task {
            env.probeIfNeeded()
        }
    }

    private func open(_ url: URL) {
        openWindow(value: url)
        dismissWindow(id: "welcome")
    }
}
