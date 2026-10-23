# Changelog

All notable changes to the Synod Mac app. Every `synodlang` repository shares MAJOR.MINOR with the language version.

## Unreleased

## v0.2.2 — 2026-10-23

Implements Synod 0.2.

### Added

- Phrase completion: a popup of phrases from `synod doc --json --scope` as you type or with ⌃Space, inserting `net.Send m from a to b` with placeholders you move through with Tab.
- Prompt bar (⌘K), opt-in, that drives your own Claude Code with the bundled agent-skills: live progress, Stop, a banner of changed files, Revert and follow-up requests.
- Editor MCP server and the `synod-editor-mcp` bridge: Claude reads and edits your open buffers as "Claude Edit" undo steps over a Unix socket with a per-session token, with no network listener.
- Settings › Claude: enable the prompt bar, set the `claude` path and the model, and opt in to external Terminal access (off at every launch, with Copy MCP config and Disconnect).
- Headless checks `--completion-check`, `--claude-check`, `--mcp-check` and `--m10`, with `scripts/acceptance-m10.sh` and `scripts/acceptance-m10-live.sh` for the owner's own Claude Code login.

### Changed

- Bundled `synod` v0.2.6 and agent-skills v0.2.2; player v0.2.1 and examples v0.2.1 are unchanged. All pinned and verified in `deps.env`.
- The prompt bar's built-in tools are restricted to Read, Glob and Grep (`--tools`): no shell and no subagent, so `synod get` is the user's step.
- The inspector's trace list scrolls, so the prompt bar stays visible when a trace is long.
- `scripts/acceptance-m10-live.sh` refuses to run without a terminal.
- Release builds must pass the M8, M9 and M10 acceptance runs first.

## v0.2.1 — 2026-10-22

Implements Synod 0.2.

### Added

- Editor: syntax highlighting from `synod check --tokens`, live diagnostics with underlines and quick fixes (⌘.), format on save (⌘S) and go to definition, with prompts for unsaved changes.
- Predict choices: questions asked with `choosing` show numbered buttons (keys 1 to 6); the answer stores the choice.
- Break it: click a node to crash or restart it, click a message to drop it and drag a box to partition nodes; each action inserts a block into `define main` at the chosen simulated time and re-runs.
- Compare: two seeds, or a program before and after Break it, side by side on one timeline.
- Click a node or message on the stage to select it.
- GIF export (480 to 960 px, 10 to 50 fps, with a time range) in the export sheet and `--export … .gif`.
- App icon.
- Headless checks `--editor-check`, `--predict-check`, `--hit-check`, `--breakit-check`, `--compare-check`, `--gif-check` and `--m9`, with `scripts/acceptance-m9.sh` and a CI job that runs it on main and tags.

### Changed

- Bundled `synod` v0.2.5, player v0.2.1 and examples v0.2.1, pinned and verified in `deps.env`.
- Headless modes use a temporary data directory, so they never touch your recents or Predict answers.
- Loosened the bounds of timing-sensitive tests.
- Release builds must pass the M8 and M9 acceptance runs first.

### Fixed

- A scene shows its poster frame as soon as it loads, before it plays.
- Predict stops reliably at each question, including at the end of playback and after a seek.
- The app never resolves its own executable as the compiler.
- `Synod <folder>` and `open Synod.app --args <folder>` open the workspace on every launch, also after quitting with a window open; a Dock click with no windows shows Welcome.
- Editor text starts beside the line-number gutter instead of under it.
- Break it uses the current program's run for its default time, which stays inside the run, and shows any error in its sheet; banners sit above the stage instead of covering it.
- The unsaved-changes prompt stays attached when the window is replaced.

## v0.2.0 — 2026-10-22

Implements Synod 0.2.

### Added

- SwiftUI Mac app (macOS 15 or later) that opens a Synod workspace and lists its programs, packages and the bundled examples.
- Running programs through the bundled `synod` (check, then run) with ordered or proportional mode and an optional seed; re-runs on file changes after a 300 ms debounce, keeping the current fact; outputs stay in the cache.
- Stage hosting the shared player in a `WKWebView`, with a timeline: play, pause, previous and next fact, scrub, speeds from 0.25x to 4x, and markers for questions, captions and broken invariants.
- Inspector with node state at the current fact and the surrounding trace, and a Problems list with a read-only source view.
- Minimal Predict: playback stops at each question and stores your answer per program.
- Video export as H.264 or HEVC, 1080p or 4K, 30 or 60 fps, rendered frame by frame from the player.
- Hidden command-line modes `--smoke`, `--export` and `--acceptance`; the acceptance run exports Raft at 1080p60 and compares sampled decoded frames with the stage player.
- Bundled `synod` v0.2.4, player v0.2.0 and the examples, pinned and verified in `deps.env`; ad-hoc signed `Synod-<tag>-macos.zip` with `SHA256SUMS`.
- Package, build scripts, CI and release workflows.
