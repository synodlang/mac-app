import SwiftUI

struct SynodApp: App {
    @State private var env = AppEnvironment.shared

    private let launchURL = LaunchArguments.workspaceURL

    var body: some Scene {
        Window("Welcome to Synod", id: "welcome") {
            WelcomeView()
                .environment(env)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(launchURL == nil ? .automatic : .suppressed)
        .commands { AppCommands() }

        // With a folder on the command line the group presents that workspace at launch.
        WindowGroup("Synod", for: URL.self) { $url in
            if url != LaunchArguments.placeholder {
                WorkspaceWindow(url: url)
                    .environment(env)
            }
        } defaultValue: {
            launchURL ?? LaunchArguments.placeholder
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(launchURL == nil ? .suppressed : .presented)

        Settings {
            SettingsView().environment(env)
        }
    }
}
