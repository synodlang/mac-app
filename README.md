# mac-app

The Synod Mac app: an editor, an animated player and learning modes for watching, predicting and breaking distributed systems.

[![ci](https://github.com/synodlang/mac-app/actions/workflows/ci.yml/badge.svg)](https://github.com/synodlang/mac-app/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## Status

**v0.2.1.** The Mac app implements Synod 0.2 and adds the M9 editor and learning modes. It bundles the `synod` compiler (v0.2.5), the player (v0.2.1) and the examples (v0.2.1), so it works offline.

What works:

- Open a workspace (a folder with `synod.mod`), with a sidebar of programs, packages and the bundled examples.
- Run a program (⌘R, or on every change after a 300 ms debounce) in ordered or proportional mode, with an optional seed. Outputs go to the cache, never into your workspace.
- Play the scene on the stage, with play and pause, previous and next fact, scrubbing, speeds from 0.25x to 4x, markers for questions, captions and broken invariants, and a red banner when an invariant breaks or the run fails. A scene shows its first frame as soon as it loads.
- Edit source in the app: syntax highlighting from `synod check --tokens`, live diagnostics with underlines and quick fixes, format on save (⌘S), and go to definition.
- Predict: playback stops at each question; questions asked with choices show numbered buttons (keys 1 to 6), and answers are stored per program.
- Break it: click a node to crash or restart it, click a message to drop it, drag a box to partition nodes. Each action inserts a block into `define main` at the current simulated time, formats the file and re-runs.
- Compare: two seeds of a program, or a program before and after Break it, side by side on one timeline.
- Click a node or a message on the stage to select it and see its state in the inspector.
- Export video as H.264 or HEVC at 1080p or 4K and 30 or 60 fps, or as an animated GIF.
- Inspect nodes: exported state at the current fact, the fields that just changed, and the trace around it; read problems from `synod check` and failed runs.
- A proper app icon.
- Headless modes: `--smoke`, `--export` (mp4 or gif), `--acceptance` (a Raft 1080p60 export compared with the stage player) and `--m9` (the whole M9 acceptance), plus a check per feature (`--editor-check`, `--predict-check`, `--hit-check`, `--breakit-check`, `--compare-check`, `--gif-check`).

Still to come in M10: phrase completion and the Claude integration. Everything below the install and build sections is the plan from [06-mac-app.md](https://github.com/synodlang/dsl/blob/main/implementation/06-mac-app.md) and [07-claude-integration.md](https://github.com/synodlang/dsl/blob/main/implementation/07-claude-integration.md); the roadmap is in [10-roadmap.md](https://github.com/synodlang/dsl/blob/main/implementation/10-roadmap.md).

## Install

Download `Synod-<tag>-macos.zip` and `SHA256SUMS` from the [releases](https://github.com/synodlang/mac-app/releases), then verify and unpack:

```sh
shasum -a 256 -c SHA256SUMS
unzip Synod-*-macos.zip && mv Synod.app /Applications/
```

The app is ad-hoc signed but not notarized. On macOS 15 and later, right-click then Open no longer bypasses Gatekeeper. Either open System Settings, Privacy & Security, and choose "Open Anyway" after the first blocked launch, or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Synod.app
```

A Homebrew cask and Developer ID notarization may follow.

## Build

You need macOS 15 or later and Xcode 27 (Swift 6.2 tools or newer). There is no Xcode project; the app is a Swift package.

```sh
scripts/fetch-deps.sh   # downloads and verifies the pinned synod, player and examples into .deps/
swift build
swift test
scripts/bundle.sh       # builds build/Synod.app (universal, ad-hoc signed)
scripts/smoke.sh        # plays every bundled example headlessly (needs a GUI session)
scripts/acceptance.sh   # Raft 1080p60 export check, about 5 minutes (add --quick for a short tcp run)
scripts/acceptance-m9.sh # the whole M9 acceptance and the M8 one, writes acc-m9/report-m9.json (--quick for tcp only)
```

`deps.env` pins the bundled `synod` release, player release and examples commit, each verified against the release `SHA256SUMS` and a hash pinned in this repository. `scripts/notes.sh --tag v0.2.1` prints the CHANGELOG section used as release notes.

## Where it fits

The app does not interpret Synod. It bundles a universal `synod` binary and calls it as a subprocess. It draws with the shared [player](https://github.com/synodlang/player), hosted in a `WKWebView`.

```
editor --> synod run --scene --trace --> scene.json --> player (WKWebView)
   ^
   +-- Claude CLI writes .synod source on request
```

| Repository | What it is | Status |
| --- | --- | --- |
| [dsl](https://github.com/synodlang/dsl) | The language specification and implementation guides | Spec v0.2 |
| [compiler](https://github.com/synodlang/compiler) | The `synod` command: `fmt`, `check`, `run` | v0.2.5 released |
| [std](https://github.com/synodlang/std) | The standard library packages | In use by the compiler |
| [examples](https://github.com/synodlang/examples) | Sample programs and acceptance tests | Available |
| [player](https://github.com/synodlang/player) | Canvas library that plays `scene.json` | v0.2.1 released |
| **mac-app** (this repository) | The Mac app | v0.2.1 (M9); M10 planned |
| [agent-skills](https://github.com/synodlang/agent-skills) | Skills for coding agents | Planned (M10) |
| [synodlang.github.io](https://github.com/synodlang/synodlang.github.io) | The website and documentation | Install page live; rest planned (M11) |
| [homebrew-tap](https://github.com/synodlang/homebrew-tap) | Homebrew formula for `synod` | Updated by compiler releases |
| [scoop-bucket](https://github.com/synodlang/scoop-bucket) | Scoop manifest for `synod` | Updated by compiler releases |
| [.github](https://github.com/synodlang/.github) | Organization profile and shared workflows | Available |

## Requirements

- macOS 15 or later.
- Apple silicon first.
- Written in Swift with SwiftUI.
- Offline first: everything except "Ask Claude" works without a network.
- "Ask Claude" needs the Claude Code CLI on your machine.

## The planned window

- A **sidebar** with programs, packages and examples.
- The **stage**, where the player draws the scene.
- A **timeline**: play, pause, step to the previous or next fact, scrub, pace from 0.25x to 4x, an ordered or proportional toggle, and markers for questions, captions and broken invariants.
- An **editor** and an **inspector** side by side.

## Planned components

- **Editor.** TextKit 2 with syntax highlighting from `synod check --json --tokens`, inline diagnostics with underlines, secondary labels and quick fixes, format on save, go-to-definition across packages, and phrase completion from `synod doc`.
- **Runner.** On save, after a 300ms debounce, it runs `synod run --scene ... --trace ...`. On success it swaps the scene and keeps the current time when possible.
- **Player.** The bundled player library in a `WKWebView`, fed `scene.json` through a JavaScript bridge. It is the same renderer as the site.
- **Inspector.** The selected node's exported state at the current time, and the trace around it. Clicking a fact jumps to it.
- **Export.** Video through `AVAssetWriter` (H.264 or HEVC, 1080p or 4K, 60fps) by rendering player frames offscreen at fixed timesteps, and GIF.

## Learning modes

- **Predict.** Playback stops at every question the program asks with `lesson.Ask`. You type or pick an answer, playback continues and shows what really happened. Answers are stored per program.
- **Break it.** Click a node to crash or restart it. Click a message dot to drop that message. Drag a box around nodes to partition them. Each action inserts a line into the program's `define main` at the current simulated time, formats the file and re-runs. No language model is involved. Invariants that break are highlighted where they broke.
- **Compare.** Two programs, or one program with two seeds, side by side on a shared timeline. Shapes are matched by id.

## Claude integration

The app has a prompt bar, for example "animate Raft with 5 nodes and a leader crash". It runs the Claude Code CLI on your machine, with the workspace as the working directory, the `synod` skill from [agent-skills](https://github.com/synodlang/agent-skills) and a short list of allowed tools (`Read`, `Write`, `Edit`, and `synod check`, `run` and `doc`). Claude reuses existing packages first, verifies with `synod check`, runs the program and stops. The app streams progress into the prompt bar and plays the result.

"Explain this run" sends `synod run --summary` and asks for `lesson.Note` lines, so captions come from the simulator and cannot invent behaviour. The result is plain Synod source that you own. The language never depends on Claude: you can write, check, run and animate Synod without it.

## Workspaces

A workspace is a folder with `synod.mod`. The app stores Synod code nowhere else, so everything works with Git and the command line.

## Contributing

See Build above. CI checks line endings, trailing spaces and the final newline of text files, builds and tests the package on macOS, bundles the app and uploads it. If something in the design is unclear, open an issue or a pull request in [dsl](https://github.com/synodlang/dsl).

To try Synod today, [install the `synod` command](https://synodlang.github.io/install/).

## Why Synod

Synod is named after the Synod protocol, the core consensus algorithm in Leslie Lamport's paper "The Part-Time Parliament" (ACM Transactions on Computer Systems, 1998; first submitted in 1990). The paper tells it as the story of the parliament of the ancient Greek island of Paxos, whose part-time legislators could agree on decrees although they came and went; today the algorithm is known as Paxos. Lamport later explained it plainly in "Paxos Made Simple" (2001), and in 2013 he received the ACM A.M. Turing Award for fundamental contributions to the theory and practice of distributed and concurrent systems. His "Time, Clocks, and the Ordering of Events in a Distributed System" (1978) and his TLA+ specification language shaped how we reason about such systems. We are grateful for his work, and we hope Synod honours it by making these ideas easier to watch and understand. The app is a place to watch, predict and break these protocols.

Implements Synod 0.2 (specification: https://github.com/synodlang/dsl).

Licensed under the [Apache License 2.0](LICENSE).
