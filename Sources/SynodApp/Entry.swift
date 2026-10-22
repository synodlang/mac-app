import SwiftUI
import AppKit

/// Process entry. Hidden headless flags (--smoke, --acceptance, --export) run under
/// NSApplication without a window server presence; everything else starts the SwiftUI app.
@main
enum Entry {
    static let headlessFlags: Set<String> = ["--smoke", "--acceptance", "--export", "--stage-check"]

    static let helpText = """
    Synod: the Mac app for the Synod language.

    Usage:
      Synod [folder]                       open the app, optionally on a workspace folder
      Synod --smoke <module> [--report f]  play every program of a module headlessly
      Synod --export <module> <program> --out f.mp4
            [--size 1080p|4k] [--codec h264|hevc] [--fps 60] [--rate 1]
            [--seed N] [--mode ordered|proportional]
      Synod --acceptance <module> --out <dir> [--program raft] [--quick]
            smoke test, then export a program at 1080p60 and compare frames with the stage
      Synod --stage-check <module> [--program raft] [--report f]
            the stage draws a loaded scene while paused and Predict stops at the pause marker
      Synod --help
    """

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            return
        }
        if args.contains(where: { headlessFlags.contains($0) }) {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            // Headless runs use a fresh temporary data folder, removed when done.
            let data = FileManager.default.temporaryDirectory
                .appendingPathComponent("synod-headless-\(UUID().uuidString)", isDirectory: true)
            setenv("SYNOD_DATA_DIR", data.path, 1)
            Task { @MainActor in
                let code = await HeadlessCommands.run(args)
                try? FileManager.default.removeItem(at: data)
                fflush(stdout)
                exit(code)
            }
            app.run()
            return
        }
        SynodApp.main()
    }
}
