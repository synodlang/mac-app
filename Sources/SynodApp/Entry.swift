import SwiftUI
import AppKit

/// Process entry. Hidden headless flags (--smoke, --acceptance, --export) run under
/// NSApplication without a window server presence; everything else starts the SwiftUI app.
@main
enum Entry {
    static let headlessFlags: Set<String> = ["--smoke", "--acceptance", "--scene-acceptance", "--export", "--stage-check", "--editor-check",
                                          "--predict-check", "--hit-check", "--breakit-check", "--compare-check", "--gif-check", "--m9", "--m10",
                                          "--completion-check", "--claude-check", "--mcp-check", "--claude-live", "--new-workspace-check"]

    static let helpText = """
    Synod: the Mac app for the Synod language.

    Usage:
      Synod [folder]                       open the app, optionally on a workspace folder
      Synod --smoke <module> [--report f]  play every program of a module headlessly
      Synod --export <module> <program> --out f.mp4
            [--size 1080p|4k] [--codec h264|hevc] [--fps 60] [--rate 1]
            [--seed N] [--mode ordered|proportional]
      Synod --export <module> <program> --out f.gif
            [--width 480|640|800|960] [--fps 10|20|25|50] [--rate 1] [--from ms] [--to ms]
            [--seed N] [--mode ordered|proportional]       (a .gif extension makes a GIF)
      Synod --acceptance <module> --out <dir> [--program raft] [--quick]
            smoke test, then export a program at 1080p60 and compare frames with the stage
      Synod --scene-acceptance <scene.json>... --out <dir> [--quick]
            the same export acceptance for handmade scene files
      Synod --stage-check <module> [--program raft] [--report f]
            the stage draws a loaded scene while paused and Predict stops at the pause marker
      Synod --editor-check <module> [--report f]
            the editor on a temporary copy: tokens, live diagnostics, quick fix, save with fmt, go to definition
      Synod --completion-check <module> [--report f]
            phrase completion on a temporary copy: the scope of every file, net.Se with placeholders, receivers, timings
      Synod --claude-check <module> [--claude <fake-claude>] [--skills <agent-skills>] [--report f]
            the prompt bar against the built fake-claude: argv, environment, MCP edits, banner, Revert, Stop
      Synod --claude-live <module> --request "<text>" [--model m] [--timeout s]
            dev aid: runs the real prompt-bar path against your own Claude Code on a temporary copy, printing argv, every stream-json line, stderr and the exit status
      Synod --mcp-check <module> [--bridge <synod-editor-mcp>] [--golden tools.json] [--report f]
            the editor MCP server through the built bridge on a temporary copy: tools, edits, save, tokens, no TCP listener
      Synod --predict-check <module> [--program p] [--report f]
            every program's Predict choices: stop at each question, choose, save, play to the end
      Synod --hit-check <module> [--program p] [--report f]
            stage hit tests at every node box, then DOM clicks and a dragged box select in the model
      Synod --breakit-check <module> --script f.json [--report f]
            the Break it flow by clicks on a temporary copy (see Tests/Acceptance/cassandra-handoff.json)
      Synod --compare-check <module> <program> [--seeds 3,4] [--mode m] [--report f]
            two runs side by side: sync maps, seeks and following while playing
      Synod --gif-check <file.gif> --module <module> --program p [--width 640] [--fps 20] [--rate 1] [--samples 30] [--report f]
            decodes a GIF from --export and compares it with the stage
      Synod --m9 <module> --out <dir> [--quick]
            the whole M9 acceptance (editor, Predict, hit, Break it, Compare, GIF) plus the M8 video; writes report-m9.json
      Synod --m10 <module> --out <dir> [--quick] [--claude <fake-claude>] [--golden tools.json] [--bridge <synod-editor-mcp>]
            the M10 acceptance (completion, prompt bar with a fake claude, editor MCP server) plus --m9; writes report-m10.json
      Synod --new-workspace-check [--report f]
            File > New Workspace on a temporary folder: synod.mod, the package folder and demo, synod check, a library, an existing folder
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
        // Windows are never restored: every launch starts from the Welcome scene or the folder given.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true])
        if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: lib.appendingPathComponent("Saved Application State/io.github.synodlang.synod.savedState"))
        }
        SynodApp.main()
    }
}
