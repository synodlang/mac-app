import SwiftUI
import AppKit

/// Process entry. Hidden headless flags (--smoke, --acceptance, --export) run under
/// NSApplication without a window server presence; everything else starts the SwiftUI app.
@main
enum Entry {
    static let headlessFlags: Set<String> = ["--smoke", "--acceptance", "--export"]

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
            Task { @MainActor in
                let code = await HeadlessCommands.run(args)
                fflush(stdout)
                exit(code)
            }
            app.run()
            return
        }
        SynodApp.main()
    }
}
