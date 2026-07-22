# AGENTS.md

## Cursor Cloud specific instructions

### Platform constraint: this app cannot be built, tested, or run on the Linux cloud VM

AutoScribe is a **macOS 14+ / Apple Silicon-only** SwiftPM desktop app. The Cursor Cloud
VM is Linux x86_64, so `swift build`, `swift test`, and running the app are **not possible
here**. This is a hard platform incompatibility, not a fixable environment gap:

- `Package.swift` declares `.macOS(.v14)` as the only supported platform.
- Sources and tests import Apple-only frameworks (`AVFoundation`, `CoreAudio`,
  `ScreenCaptureKit`, `SwiftUI`), and `AutoScribeCore` links `AVFoundation`, `CoreAudio`,
  and `ScreenCaptureKit` — none of which exist on Linux.
- Dependencies require Apple hardware/toolchains: WhisperKit (CoreML) and MLX
  (`mlx-swift`, Metal / Apple Silicon GPU). On Linux, `swift build` fails early compiling
  MLX's C++/Metal backend, and would then fail on the missing macOS frameworks.
- The build/run scripts require Xcode tooling: `scripts/build-dev-app.sh` uses
  `xcrun metal`, `xcrun metallib`, and `codesign`.

### What works vs. what doesn't on the Linux cloud VM

- Works: editing/reviewing Swift source, and `swift package resolve` (all Git
  dependencies fetch successfully) if a Swift Linux toolchain is installed.
- Does not work: `swift build`, `swift test`, `./scripts/build-dev-app.sh`, and launching
  the app. Do not attempt to "fix" these by editing code — they fail because of the
  platform, not the repository.

A Swift Linux toolchain (e.g. via `swiftly`) can be installed for limited static analysis
and dependency resolution only; it will not produce a working build.

### Building / testing / running (requires macOS + Apple Silicon)

These are documented in `README.md` and only succeed on an Apple Silicon Mac with Xcode:

- Build dev app: `./scripts/build-dev-app.sh`
- Run: `open .build/AutoScribe.app` (grant Microphone + Screen/System Audio permissions)
- Test: `swift test`
- No linter is configured (no SwiftLint/SwiftFormat config present).

### Configuration notes

- The default processing mode is fully on-device/offline — no services, database, ports,
  or API keys are required for end-to-end use.
- `OPENAI_API_KEY` is optional and only used in API processing mode. It is loaded (in
  order) from the process env, the app bundle `.env`, the current directory `.env`,
  `~/Documents/AutoScribe/.env`, then `~/.autoscribe/.env`. See `.env.example`.
