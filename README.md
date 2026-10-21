# mac-app

The Synod Mac app: an editor, an animated player and learning modes for watching, predicting and breaking distributed systems.

[![ci](https://github.com/synodlang/mac-app/actions/workflows/ci.yml/badge.svg)](https://github.com/synodlang/mac-app/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Status: designed, not yet written.** This repository has no code yet. The app arrives over milestones M8 (open a workspace, run, play, timeline, inspector, video export), M9 (editor, Predict, Break it, Compare) and M10 (Claude integration) of the [roadmap](https://github.com/synodlang/dsl/blob/main/implementation/10-roadmap.md). It depends on the scene builder (M5) and the player (M7). Everything below is the plan from [06-mac-app.md](https://github.com/synodlang/dsl/blob/main/implementation/06-mac-app.md) and [07-claude-integration.md](https://github.com/synodlang/dsl/blob/main/implementation/07-claude-integration.md).

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
| [compiler](https://github.com/synodlang/compiler) | The `synod` command: `fmt`, `check`, `run` | v0.2.2 released |
| [std](https://github.com/synodlang/std) | The standard library packages | In use by the compiler |
| [examples](https://github.com/synodlang/examples) | Sample programs and acceptance tests | Available |
| [player](https://github.com/synodlang/player) | Canvas library that plays `scene.json` | Planned (M7) |
| **mac-app** (this repository) | The Mac app | Planned (M8, M9, M10) |
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

There is nothing to build yet. If you want to help before the code exists, read the two design documents above and open an issue or a pull request in [dsl](https://github.com/synodlang/dsl) when something is unclear. This repository's CI today checks line endings, trailing spaces and the final newline. Swift build and test jobs will be added with the first code.

To try Synod today, [install the `synod` command](https://synodlang.github.io/install/).

## Why Synod

Synod is named after the Synod protocol, the core consensus algorithm in Leslie Lamport's paper "The Part-Time Parliament" (ACM Transactions on Computer Systems, 1998; first submitted in 1990). The paper tells it as the story of the parliament of the ancient Greek island of Paxos, whose part-time legislators could agree on decrees although they came and went; today the algorithm is known as Paxos. Lamport later explained it plainly in "Paxos Made Simple" (2001), and in 2013 he received the ACM A.M. Turing Award for fundamental contributions to the theory and practice of distributed and concurrent systems. His "Time, Clocks, and the Ordering of Events in a Distributed System" (1978) and his TLA+ specification language shaped how we reason about such systems. We are grateful for his work, and we hope Synod honours it by making these ideas easier to watch and understand. The app is a place to watch, predict and break these protocols.

Implements Synod 0.2 (specification: https://github.com/synodlang/dsl).

Licensed under the [Apache License 2.0](LICENSE).
