# Bug Fixes

## Test environment

- Date: July 12, 2026
- Operating system: macOS 26.5.2 (build 25F84)
- Architecture: Apple Silicon (`arm64`)
- Swift: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`)
- Swift target: `arm64-apple-macosx26.0`

## Application unexpectedly exits

### Symptoms

- MeetingNotes appeared to quit unexpectedly on one laptop.
- Quitting during recording could discard unsaved audio.
- There was not enough persistent information to distinguish a crash from a normal exit.

### Fixes

- Disabled macOS automatic termination while MeetingNotes is running.
- Added graceful quit handling for recording and processing states.
- Added Stop and Save, Continue, and Quit and Discard choices when quitting during recording.
- Added persistent diagnostic logging at `~/Library/Logs/MeetingNotes/MeetingNotes.log`.
- Added abnormal-exit detection and incident bundles under `~/Library/Logs/MeetingNotes/Crash Reports`.
- Added a Crash Reports button to Diagnostics.
- Added recording recovery workspaces under `~/Library/Application Support/MeetingNotes/Recording Recovery`.
- Added startup reporting for recoverable recordings.

## Processing appears stuck after recording

### Symptoms

- Audio recording stopped successfully and both WAV files were written.
- The app remained in Processing while using approximately one CPU core.
- Runtime sampling showed that the main thread was alive and MLX was continuously generating the summary.

### Cause

The local MLX model was allowed to generate without a maximum output-token limit. If the model failed to emit its end-of-sequence signal, summary generation could continue indefinitely. This did not limit or interrupt Whisper transcription.

### Fix

MeetingNotes now enforces summary output limits:

- Brief summary: 384 tokens
- Standard summary: 640 tokens
- Detailed summary: 1,024 tokens

These limits apply only to the generated summary. The full audio transcription is still processed separately.

## Microphone transcript retains speaker-bleed duplicates

### Symptoms

- In a Zoom/speaker test, the microphone transcript contained the same sentence already captured in the System Audio stream.
- The summary listed both the Microphone and System Audio versions of identical speech (e.g. "Okay, this is a testing for MeetingNotes…" appeared twice).

### Cause

`TranscriptDeduplicator` compared sentences individually using Levenshtein similarity with a 0.95 threshold and a strict 5% length pre-filter. Speaker bleed introduces small differences between the two streams:

1. Whisper splits the system-audio text differently — a short prefix word (e.g. "Okay.") becomes its own sentence, so the remaining sentence starts one word later than the microphone version.
2. Punctuation and minor word-boundary differences (e.g. "auto-scribe" → "auto scribe" vs "meetingnotes") push character-level similarity just below 0.95 (~0.94), causing the sentence to slip through.
3. The 5% length pre-filter returned 0 before Levenshtein even ran when the prefix word produced a ~5–10% length gap.

### Fix

Three changes to `TranscriptDeduplicator.swift`:

- **Threshold lowered 0.95 → 0.82.** Real-world speaker bleed reduces Levenshtein similarity to ~0.93–0.94 due to short prefix words and minor transcription differences. 0.82 catches these while leaving genuinely unique mic content untouched.
- **Length pre-filter relaxed 5% → 30%.** The 5% cap was too strict — a single extra prefix word inflates the length difference to ~8–10%, causing the filter to short-circuit and return 0 before comparison.
- **Jaccard word-overlap added as a second signal.** If two sentences share ≥82% of their unique words, the sentence is treated as a duplicate regardless of character-level differences. This cleanly handles cases like "auto scribe" vs "meetingnotes" that confuse Levenshtein.

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
- Updated the API processing provider to use `textForSummarization` for consistency.

## Zoom cannot be used when MeetingNotes starts first

### Symptoms

- If MeetingNotes is started before Zoom, Zoom cannot be used normally.
- Zoom works when it is opened first and MeetingNotes recording is started afterward.

### Steps to reproduce

1. Start MeetingNotes.
2. Start recording in MeetingNotes.
3. Open Zoom and attempt to start or join a meeting.
4. Observe that Zoom cannot be used normally.

### Expected behavior

Zoom should open and work normally regardless of whether MeetingNotes is already running or recording.

### Cause

MeetingNotes preferred a Core Audio process tap that created a private aggregate audio device. When MeetingNotes started that device before Zoom initialized its audio session, Zoom could hang. A denied ScreenCaptureKit permission also caused MeetingNotes to fall back automatically to the same conflicting Core Audio path.

### Fix

- Made ScreenCaptureKit the only automatic system-audio backend.
- Removed the automatic Core Audio Tap fallback so a missing permission cannot reintroduce the Zoom conflict or trigger a second permission request.
- Added a guided permission onboarding flow for Microphone and Screen & System Audio Recording.
- Added live permission preflight checks so recording cannot repeatedly trigger macOS permission dialogs.
- Added a required-restart step after Screen & System Audio Recording is enabled.

### Verification

- Confirmed Zoom works when MeetingNotes starts recording first.
- Confirmed Zoom works when it starts before MeetingNotes.
- Confirmed diagnostics identify ScreenCaptureKit as the system-audio backend.

## Onboarding does not reappear after granting system-audio access

### Symptoms

- During onboarding, MeetingNotes asks the user to grant Screen & System Audio Recording access.
- The restart action quits MeetingNotes as expected, but no onboarding window reappears.
- MeetingNotes relaunches as a background menu-bar process, so the user must open it manually to continue onboarding.

### Steps to reproduce

1. Install and open MeetingNotes.
2. Continue through onboarding to Screen & System Audio Recording permission.
3. Grant MeetingNotes access in System Settings.
4. Return to onboarding and click **Restart MeetingNotes**.
5. Observe that MeetingNotes relaunches without showing onboarding.

### Expected behavior

MeetingNotes should quit and reopen automatically, bring onboarding to the front, verify the permission, and resume at the Ready screen.

### Actual behavior

MeetingNotes relaunches in the background without making the onboarding window visible.

### Cause

The relaunch helper successfully started a new MeetingNotes process, but macOS classified the `LSUIElement` app as background/not visible. The app did not preserve an explicit permission-relaunch signal for startup, and the normal window activation call was not sufficient to bring onboarding forward from that launch state.

### Fix

- Preserve whether the controller was initialized after a requested permission relaunch.
- Force onboarding presentation when that relaunch signal is present, even if other setup state appears complete.
- Bring the onboarding window forward with `orderFrontRegardless`, activate all app windows, and retry activation after AppKit restores the menu-bar scene.
- Add persistent diagnostics for the onboarding launch decision and window visibility.

### Status

Fix implemented; installed-DMG verification is still required.

## Long recordings produce an empty note and lose the audio

### Symptoms

- A ~40-minute meeting recorded successfully (microphone and system-audio files were written), but the resulting note was empty ("No transcript was generated for this captured source").
- The diagnostic log showed `Summarization failed (The request timed out.)` roughly 60 seconds after processing began, followed by `Temporary files cleaned up.`
- The raw audio was no longer on disk afterward, so the recording could not be reprocessed.

### Steps to reproduce

1. Record a long meeting (tens of minutes) with API processing mode.
2. Stop the recording and wait for processing.
3. Observe an empty summary/transcript and, in the log, a timeout during processing.

### Cause

- Transcription uploaded each capture file in a single request using `URLSession.shared`, whose default 60-second request timeout is far too short for a long recording. The uncompressed microphone WAV (~116 MB for 40 minutes) also exceeded the hosted transcription API's upload size limit.
- The error handler that catches processing failures was written for summarization errors. Because transcription runs first inside the same call, a transcription failure was mislabeled "Summarization failed," an empty note was written, and cleanup then deleted the raw audio — so the recording was lost.

### Fix

- Preserve the raw audio and surface the real error when transcription (as opposed to summarization) fails, instead of writing an empty note and deleting the recording. Failed recordings are kept in `~/Documents/MeetingNotes/<date>_unprocessed/`.
- Downsample audio to 16 kHz mono AAC and split it into 20-minute chunks before upload, so long meetings stay well under the API file-size limit; transcript timestamps are stitched back onto the original timeline using each chunk's offset.
- Give the Groq client a dedicated `URLSession` with a 300-second request timeout and 30-minute resource timeout instead of the 60-second shared default.
- Added `TranscriptionUploadPreparer` with tests covering 16 kHz mono downsampling and the fallback path for unreadable input.

### Status

Fix implemented and unit-tested. End-to-end verification against the live transcription API with a long recording is still recommended.

## Long transcripts exceed the Groq summarization token limit

### Symptoms

- A 32-minute API-mode recording produced a complete raw transcript, but the generated meeting note contained no summary.
- The fallback meeting note also incorrectly said that no transcript was generated even though the raw transcript had been saved successfully.

### Observed error

Groq rejected the summary request for `openai/gpt-oss-20b` because the organization had an 8,000 tokens-per-minute limit and the request required 9,173 tokens.

### Cause

MeetingNotes sends the entire transcript to the summary model in one request and does not account for the active model, organization, and service tier's token limits. Groq limits can vary by model and account tier, so a fixed transcript-length threshold would not be reliable.

### Proposed fix

- Split long transcripts into bounded chunks, summarize each chunk, then merge the partial summaries into the final meeting summary.
- Use Groq rate-limit response headers when available to adjust future request sizes, but do not depend on those headers being known before the first request.
- If Groq still rejects a request as too large, automatically retry with smaller chunks.
- Reserve enough of the token budget for the requested summary output.
- When summarization fails after transcription succeeds, include the successful transcript in the main Markdown file instead of writing an empty transcript section.

### Status

Closed by product simplification on Sep 19, 2026. MeetingNotes no longer requests summaries or calls a chat-completion model; each recording now produces only the raw transcript file.

## Verification

- Confirmed that audio remained available in Recording Recovery after terminating the stuck process.
- Confirmed through process sampling that the observed problem was active MLX generation, not a crash or main-thread deadlock.
- Rebuilt and launched the updated app successfully.
- Ran 36 automated tests with zero failures.
