import AppKit
import SwiftUI

struct SynodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment.shared

    private let launchURL = LaunchArguments.workspaceURL

    var body: some Scene {
        // Always the launch window. With a folder on the command line it stays invisible, opens
        // that workspace through `openWindow` and closes itself (see `LaunchRouter`): the
        // launch behaviors of a value-based `WindowGroup` did not present a window reliably.
        Window("Welcome to Synod", id: "welcome") {
            LaunchRouter(url: launchURL) { WelcomeView().environment(env) }
        }
        .windowResizability(.contentSize)
        .commands { AppCommands() }

        WindowGroup("Synod", for: URL.self) { $url in
            if let url {
                WorkspaceWindow(url: url)
                    .environment(env)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView().environment(env)
        }
    }
}

/// Shows the Welcome content, or, when a workspace folder was given on the command line, opens
/// that workspace once at launch while its own window stays invisible.
struct LaunchRouter<Content: View>: View {
    let url: URL?
    @ViewBuilder var content: () -> Content
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var routing: Bool

    init(url: URL?, @ViewBuilder content: @escaping () -> Content) {
        self.url = url
        self.content = content
        _routing = State(initialValue: url != nil && !LaunchArguments.routed)
    }

    var body: some View {
        if routing, let url {
            Color.clear
                .frame(width: 1, height: 1)
                .background(WindowHider())
                .task {
                    LaunchArguments.routed = true
                    openWindow(value: url)
                    try? await Task.sleep(for: .milliseconds(150))
                    dismissWindow(id: "welcome")
                    routing = false
                }
        } else {
            content()
        }
    }
}

/// Makes the hosting window fully transparent and inert while it routes the launch.
private struct WindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.alphaValue = 0
            v.window?.ignoresMouseEvents = true
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
