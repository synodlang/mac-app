# Changelog

All notable changes to the Synod Mac app. Every `synodlang` repository shares MAJOR.MINOR with the language version.

## Unreleased

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
