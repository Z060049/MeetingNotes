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

## Microphone transcript retains speaker-bleed duplicates

### Symptoms

- In a Zoom/speaker test, the microphone transcript contained the same sentence already captured in the System Audio stream.
- The summary listed both the Microphone and System Audio versions of identical speech (e.g. "Okay, this is a testing for AutoScribe…" appeared twice).

### Cause

`TranscriptDeduplicator` compared sentences individually using Levenshtein similarity with a 0.95 threshold and a strict 5% length pre-filter. Speaker bleed introduces small differences between the two streams:

1. Whisper splits the system-audio text differently — a short prefix word (e.g. "Okay.") becomes its own sentence, so the remaining sentence starts one word later than the microphone version.
2. Punctuation and minor word-boundary differences (e.g. "auto-scribe" → "auto scribe" vs "autoscribe") push character-level similarity just below 0.95 (~0.94), causing the sentence to slip through.
3. The 5% length pre-filter returned 0 before Levenshtein even ran when the prefix word produced a ~5–10% length gap.

### Fix

Three changes to `TranscriptDeduplicator.swift`:

- **Threshold lowered 0.95 → 0.82.** Real-world speaker bleed reduces Levenshtein similarity to ~0.93–0.94 due to short prefix words and minor transcription differences. 0.82 catches these while leaving genuinely unique mic content untouched.
- **Length pre-filter relaxed 5% → 30%.** The 5% cap was too strict — a single extra prefix word inflates the length difference to ~8–10%, causing the filter to short-circuit and return 0 before comparison.
- **Jaccard word-overlap added as a second signal.** If two sentences share ≥82% of their unique words, the sentence is treated as a duplicate regardless of character-level differences. This cleanly handles cases like "auto scribe" vs "autoscribe" that confuse Levenshtein.

## Summary section contains raw transcript lines instead of insights

### Symptoms

- The `## Summary` section in the output Markdown listed raw speaker-labelled lines like `"Microphone: Okay, this is a testing for auto-scribe…"` instead of synthesized bullet points.
- A hallucinated word ("University") from Whisper appeared as a fake speaker label in the summary.
- The `>>` WhisperKit artifact appeared verbatim in the summary output.
- Some summary lines were duplicated.

### Cause

Three issues combined:

1. **Speaker labels in the LLM input.** `plainText` fed `"Microphone: …"` and `"System Audio: …"` prefixes directly to the model. Qwen 0.5B (the default local model) is too small to abstract over these labels, so it copied the transcript lines verbatim into `keyPoints` rather than summarizing.
2. **WhisperKit `>>` artifact.** WhisperKit sometimes prepends `>>` to system audio output; this appeared raw in the LLM input and propagated into the summary.
3. **Whisper hallucination treated as a speaker.** Whisper misheard a word mid-sentence and inserted `"University,"`. With speaker labels present in the input, the model treated `"University:"` as a third participant and duplicated the following line.

### Fix

- Added `textForSummarization` to `Transcript` (`TranscriptModels.swift`). It merges all segments into clean prose, stripping speaker labels, `>>` prefixes, and `[silence]` filler tokens before the text is sent to any LLM.
- Updated `buildPrompt` in `LocalSummarizationService.swift` to use `textForSummarization` and added an explicit rule: *"Write each keyPoint as a concise insight in your own words — do not copy transcript sentences verbatim."*
- Updated `OpenAIProcessingProvider.swift` to use `textForSummarization` for consistency.

## Verification

- Confirmed that audio remained available in Recording Recovery after terminating the stuck process.
- Confirmed through process sampling that the observed problem was active MLX generation, not a crash or main-thread deadlock.
- Rebuilt and launched the updated app successfully.
- Ran 36 automated tests with zero failures.
