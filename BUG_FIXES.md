# Bug Fixes

## Test environment

- Date: July 12, 2026
- Operating system: macOS 26.5.2 (build 25F84)
- Architecture: Apple Silicon (`arm64`)
- Swift: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`)
- Swift target: `arm64-apple-macosx26.0`

## Application unexpectedly exits

### Symptoms

- AutoScribe appeared to quit unexpectedly on one laptop.
- Quitting during recording could discard unsaved audio.
- There was not enough persistent information to distinguish a crash from a normal exit.

### Fixes

- Disabled macOS automatic termination while AutoScribe is running.
- Added graceful quit handling for recording and processing states.
- Added Stop and Save, Continue, and Quit and Discard choices when quitting during recording.
- Added persistent diagnostic logging at `~/Library/Logs/AutoScribe/AutoScribe.log`.
- Added abnormal-exit detection and incident bundles under `~/Library/Logs/AutoScribe/Crash Reports`.
- Added a Crash Reports button to Diagnostics.
- Added recording recovery workspaces under `~/Library/Application Support/AutoScribe/Recording Recovery`.
- Added startup reporting for recoverable recordings.

## Processing appears stuck after recording

### Symptoms

- Audio recording stopped successfully and both WAV files were written.
- The app remained in Processing while using approximately one CPU core.
- Runtime sampling showed that the main thread was alive and MLX was continuously generating the summary.

### Cause

The local MLX model was allowed to generate without a maximum output-token limit. If the model failed to emit its end-of-sequence signal, summary generation could continue indefinitely. This did not limit or interrupt Whisper transcription.

### Fix

AutoScribe now enforces summary output limits:

- Brief summary: 384 tokens
- Standard summary: 640 tokens
- Detailed summary: 1,024 tokens

These limits apply only to the generated summary. The full audio transcription is still processed separately.

## Verification

- Confirmed that audio remained available in Recording Recovery after terminating the stuck process.
- Confirmed through process sampling that the observed problem was active MLX generation, not a crash or main-thread deadlock.
- Rebuilt and launched the updated app successfully.
- Ran 36 automated tests with zero failures.
