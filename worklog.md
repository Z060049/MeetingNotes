# July 14, 2026

## Stability and diagnostics

- Added persistent rotating diagnostic logs under `~/Library/Logs/AutoScribe`.
- Added automatic crash incident bundles with session state, application logs, and matching macOS crash reports.
- Added recording-recovery storage so unprocessed audio survives unexpected exits.
- Prevented macOS automatic termination and added safe quit handling while recording or processing.
- Added a diagnostics UI shortcut for opening crash reports.
- Added scripts for collecting a debug baseline and testing the idle application lifecycle.

## Local processing

- Diagnosed processing that appeared stuck after recording.
- Added output-token limits to local MLX summary generation.
- Improved build checks for the required Metal toolchain and compiled Metal resources.

## Interface

- Hid the API processing mode for the local-first release and documented it in the PRD.
- Removed unnecessary empty space from the menu-bar popover and settings view.
- Added dynamic popover resizing as content and audio-route status change.
- Fixed the menu-bar popover becoming inaccessible or clipped after recording and route transitions.

## Transcript quality

- Removed Whisper control and timestamp tokens from raw transcripts.
- Added session-relative start and end timestamps to transcript segments.
- Preserved timing offsets introduced by delayed capture starts and silence trimming.
- Added timestamp-aware microphone echo removal while preserving unique and short overlapping responses.
- Added deduplication reports and persistent diagnostics.
- Added regression tests for fragmented echo, mixed microphone content, short responses, timestamp alignment, and Whisper text sanitization.

## Audio-device hot swapping

- Diagnosed the AirPods crash as an `AVAudioEngine` input-graph abort when the active microphone disappeared.
- Replaced the long-lived microphone engine with restartable `AVCaptureSession` capture.
- Added debounced monitoring for default input, output, and device-list changes.
- Added serialized route-transition handling with safe cancellation when Stop Recording is pressed.
- Added independent microphone and system-audio reconnects so an unaffected source can continue.
- Added uniquely named, timeline-aligned audio segments across device changes.
- Added route identity and segment metadata to captured files.
- Added non-blocking “Switching audio device…” status and detailed transition diagnostics.
- Fixed AirPods reconnection by safely matching Core Audio and AVFoundation device identifiers, waiting for Bluetooth input availability, and retrying bounded reconnects.
- Fixed cancellation being reported as a false reconnect failure or restoration.
- Added deterministic tests for built-in, AirPods, wired, input-only, output-only, missing-device, reconnect-failure, repeated-event, and Stop-during-reconnect scenarios.

## Verification

- The complete Swift test suite passes: 58 tests with no failures.
- The development application builds and signs successfully with `./scripts/build-dev-app.sh`.
- The corrected development build was relaunched for manual AirPods testing.
