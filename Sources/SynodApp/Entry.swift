import SwiftUI
import AppKit

/// Process entry. Hidden headless flags (--smoke, --acceptance, --export) are dispatched
/// here once HeadlessCommands exists; everything else starts the SwiftUI app.
@main
enum Entry {
    static let headlessFlags: Set<String> = ["--smoke", "--acceptance", "--export"]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("""
            Synod

            Headless flags implemented: none yet
            """)
            return
        }
        if args.contains(where: { headlessFlags.contains($0) }) {
            // TODO(tasks D/E): run HeadlessCommands under NSApplication with .prohibited policy.
            FileHandle.standardError.write(Data("Synod: headless flag not implemented\n".utf8))
            exit(2)
        }
        SynodApp.main()
    }
}

struct SynodApp: App {
    var body: some Scene {
        WindowGroup("Synod") {
            Text("Synod")
                .font(.largeTitle)
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
