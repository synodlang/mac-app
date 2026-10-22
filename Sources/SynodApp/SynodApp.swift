import SwiftUI

struct SynodApp: App {
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        Window("Welcome to Synod", id: "welcome") {
            WelcomeView()
                .environment(env)
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

        Settings {
            SettingsView().environment(env)
        }
    }
}
