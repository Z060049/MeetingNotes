# AutoScribe PRD

## 1) Product overview

AutoScribe is a macOS background app that captures both sides of a conversation (microphone + system audio), transcribes it, and outputs clean notes as Markdown.

It is designed for real-world meeting workflows where built-in recording is unavailable or restricted (Zoom, Google Meet/Hangouts, Microsoft Teams, phone calls via MacBook audio).

Core value:
- Universal capture independent of meeting platform
- Fast, searchable Markdown output for Obsidian or any notes app
- Optional privacy-first local processing mode

## Current implementation status

Status as of Jun 24, 2026:
- Native macOS Swift/SwiftUI menu-bar MVP has been implemented.
- The app currently runs as a local development `.app` bundle built from Swift Package Manager.
- Manual menu-bar recording works for the tested happy path.
- Microphone and system audio are captured into separate temporary files.
- OpenAI API mode can transcribe, summarize, and export Markdown successfully.
- Markdown output has been validated with a short real recording and saved to `~/Documents/AutoScribe/`.
- Local processing remains deferred.

Current development workflow:
- Build the local test app with `./scripts/build-dev-app.sh`.
- Launch the app with `open .build/AutoScribe.app`.
- For shortcut testing, grant Accessibility permission to `.build/AutoScribe.app`.
- Store the OpenAI API key through the app settings UI; the key is saved in macOS Keychain.

Validated output example:
- A short recording successfully generated a Markdown file with metadata, summary sections, and separate `Microphone` / `System Audio` transcript sections.

## 2) Problem statement

People regularly lose important meeting details because:
- Recording is not permitted by host settings
- Notes are incomplete while multitasking in live calls
- Existing tools are tied to specific meeting platforms

Users need a single Mac-native tool that works everywhere, starts/stops quickly, and produces reliable transcript + summary output without workflow friction.

## 3) Goals and non-goals

### Goals
- Run as a lightweight background macOS app
- Start/stop capture quickly via keyboard shortcut (double-tap Command key)
- Capture dual audio streams:
  - Local microphone input (user speech)
  - System/output audio (remote speaker audio from meeting app)
- Auto-stop when inactive for 5 minutes (configurable)
- Generate:
  - Full transcript in Markdown
  - Structured summary in Markdown
- Support two processing modes:
  - Local LLM/STT path (privacy-first, no API cost)
  - Third-party API path (simpler to ship first)

### Implementation choices made for MVP
- App stack: native macOS Swift/SwiftUI menu-bar app.
- Packaging during development: Swift Package Manager executable wrapped into a local `.app` bundle.
- API provider: OpenAI for speech-to-text and summarization.
- API key storage: macOS Keychain.
- Audio capture strategy:
  - Microphone: AVFoundation recording to `.wav`.
  - System audio: ScreenCaptureKit recording to `.m4a`.
- Speaker labeling in MVP: best-effort by capture stream (`Microphone` vs `System Audio`), not true diarization.

### Non-goals (v1)
- Live captions in-call
- Collaborative/shared notes
- Mobile app support
- Full meeting analytics dashboard
- Automatic CRM/task integrations

## 4) Target users

- Job seekers and interviewers
- Founders and operators in frequent remote meetings
- Consultants, PMs, engineers, and researchers
- Privacy-sensitive users who prefer local processing

## 5) User stories

- As a user, I can start recording from anywhere using a global shortcut without opening a full app window.
- As a user, I can capture both my voice and the other participant audio regardless of meeting platform.
- As a user, I receive a readable Markdown file with transcript and concise summary immediately after the meeting.
- As a user, I can rely on auto-stop if I forget to manually stop recording.
- As a privacy-focused user, I can keep processing fully local on my device.
- As a convenience-focused user, I can choose cloud/API processing for faster setup.

## 6) Functional requirements

### 6.1 Recording control
- Global hotkey: double-tap Command key to start/stop recording
- First-run UX should explain that double-tap Command requires macOS Accessibility permission.
- If Accessibility permission is not granted, manual menu-bar start/stop should still work.
- Tray/menu bar presence with clear state:
  - Idle
  - Recording
  - Processing
  - Complete
- Manual stop action from menu bar
- Auto-stop after 5 minutes of inactivity (no detected speech or audio above threshold)
- Optional confirmation sound or toast on start/stop

### 6.2 Audio capture
- Capture microphone input stream
- Capture system audio/output stream
- Timestamp and merge streams for aligned transcription context
- Handle device changes gracefully (mic unplug, audio route changes)
- Store temporary audio safely, then clean up after processing

### 6.3 Transcription + summarization
- Transcribe meeting audio into diarized or speaker-labeled text where possible
- For MVP, label transcript segments by capture source (`Microphone`, `System Audio`) rather than full speaker diarization.
- Produce meeting summary with:
  - Key points
  - Decisions
  - Action items
  - Follow-ups/questions
- Generate Markdown output with consistent template

### 6.4 File output
- Save `.md` output to configurable folder (default: `~/Documents/AutoScribe/`)
- Filename format: `YYYY-MM-DD_HH-mm_<meeting-title-or-generic>.md`
- Include metadata header:
  - Date/time
  - Duration
  - Processing mode (Local/API)
  - Audio sources captured

### 6.5 Settings
- Toggle processing mode (Local vs API)
- Configure inactivity timeout (default 5 min)
- Configure output folder
- Configure summary depth (brief/standard/detailed)
- Configure consent reminder prompt before capture
- Configure/store OpenAI API key securely via Keychain

## 7) User experience requirements

- Zero-friction launch at login (optional)
- Recording state always visible in menu bar icon state/color
- Post-processing should feel automatic and under 1-3 minutes for common meeting lengths
- Output Markdown should be immediately useful without manual cleanup

## 8) Privacy, security, and compliance requirements

- Explicitly warn users about local laws regarding recording consent
- First-run consent/compliance checklist
- First-run Accessibility permission guidance for global shortcut support
- Clear indicator when recording is active
- Local mode:
  - Audio/transcript stays on device
  - No network transfer for content processing
- API mode:
  - Disclose provider, retention behavior, and data handling
  - Offer "do not store" where provider supports it
- Secure temporary file handling and deletion after processing
- No background recording without explicit user start

## 9) Technical approaches

## 9.1 Path A: API-first (faster MVP)
Pros:
- Faster implementation and time-to-market
- Lower local compute requirements
- Better out-of-the-box transcription quality with managed models

Cons:
- Ongoing API cost
- Privacy concerns for some users
- Internet dependency

Recommended for:
- MVP launch to validate demand quickly

## 9.2 Path B: Local-first (privacy moat)
Pros:
- Strong privacy positioning ("notes never leave your machine")
- No per-minute API costs
- Works offline (for processing once recording is available)

Cons:
- Higher engineering complexity
- Model packaging/performance constraints on lower-end Macs
- More QA complexity across Apple Silicon generations

Recommended for:
- v1.5/v2 after MVP validation, or parallel track if resourced

## 10) Suggested rollout strategy

Phase 1 (MVP, 4-8 weeks):
- Implement stable dual-source recording
- Ship API-based transcription + summary
- Deliver Markdown export and core settings

Phase 2:
- Improve speaker labeling, summary quality, and reliability
- Add better post-meeting structure templates

Phase 3:
- Introduce local processing beta mode
- Benchmark accuracy/speed/cost vs API mode
- Promote privacy-first value in product messaging

## 11) Success metrics

- Activation:
  - % of installed users who complete first recording
- Reliability:
  - % sessions with successful dual-source capture
  - Crash-free sessions
- Output quality:
  - User rating for transcript usefulness
  - User rating for summary usefulness
- Engagement:
  - Weekly recordings per active user
- Business:
  - API cost per recorded hour (API mode)
  - Conversion to paid tier (if applicable)

## 12) Risks and mitigations

- Audio capture complexity on macOS
  - Mitigation: early prototype and stress test audio routing cases
- macOS permission friction
  - Mitigation: first-run onboarding, settings deep links, refresh status, and clear manual fallback
- Legal/compliance concerns
  - Mitigation: strong consent UX + jurisdiction reminders
- Summary hallucinations or missed context
  - Mitigation: keep transcript + summary side-by-side, improve prompts/models
- Transcription hallucinations on silent or near-empty audio
  - Mitigation: skip tiny system-audio files before sending to STT; add stronger silence detection in a future pass
- High latency for long recordings
  - Mitigation: chunked transcription and progress indicators

## 12.1 Bugs found and fixed during MVP testing

- Standard copy/paste did not work in the OpenAI API key field.
  - Cause: the menu-bar app did not install a normal macOS Edit menu.
  - Fix: added Cut, Copy, Paste, and Select All menu commands.
- Double-tap Command did not trigger recording during development testing.
  - Cause: macOS Accessibility permission was not granted to the launched app/process.
  - Fix: added diagnostics, first-run permission guidance, settings deep link, and a dev `.app` bundle so AutoScribe appears clearly in Accessibility settings.
- Accessibility settings were confusing when launching with `swift run`.
  - Cause: macOS associated permissions with the launcher/build artifact rather than a normal app.
  - Fix: added `scripts/build-dev-app.sh` to create `.build/AutoScribe.app` for realistic local permission testing.
- System audio recording failed with `The audio writer was not available`.
  - Cause: `.m4a` `AVAssetWriterInput` lacked explicit AAC output settings.
  - Fix: configured AAC sample rate, channel count, and bit rate for system audio output.
- OpenAI transcription rejected microphone audio.
  - Cause: microphone was recorded as `.caf`, which OpenAI speech-to-text does not support.
  - Fix: switched microphone recording to `.wav` and selected upload MIME types by extension.
- Processing failed with an invalid summary response.
  - Cause: summary parsing expected a single exact JSON response shape.
  - Fix: requested strict JSON schema from OpenAI, added response-shape fallbacks, and improved error diagnostics.
- Silent or near-silent system audio produced plausible fake transcript text.
  - Cause: STT can hallucinate on tiny/silent audio files.
  - Fix: added a first-pass guard that skips very small system-audio files and logs captured file sizes for tuning.
- AirPods/Bluetooth routes were blocked after earlier testing found they could leave the app in a headless/stuck recording state.
  - Cause: startup rejected any route whose device name contained AirPods/Bluetooth, and the UI entered `Recording` before capture startup had actually succeeded.
  - Fix: added route capability metadata, made startup transactional, allowed AirPods routes, preferred ScreenCaptureKit before Core Audio Tap for Bluetooth output, and preserved microphone recording with clear diagnostics if system audio fails.

## 12.2 Known remaining issues and follow-ups

- Accessibility permission is still reported as not trusted in current testing until the user grants permission to `.build/AutoScribe.app` and relaunches.
- The current `.app` bundle is a development wrapper, not a signed/notarized production app.
- System-audio silence detection is currently based on file size; it should be upgraded to real audio-level/silence analysis.
- System audio capture needs broader manual testing across Zoom, Google Meet, Teams, browser playback, speakers, wired headphones, AirPods/Bluetooth routes, and phone-call routing.
- Multilingual support (e.g. Mandarin) is only partial: Whisper transcription auto-detects and works, but (a) the summary language is not pinned to the transcript's language, (b) the transcript de-duplication sentence splitter only handles ASCII `.!?` and misses full-width CJK punctuation (`。！？`), and (c) the Whisper request sends an English hint prompt. Action item: pin summary language to the transcript, add CJK punctuation to the de-dup splitter, and drop/localize the Whisper hint prompt.
- Keychain prompts are visible in the development build and may need a clearer production signing/access-group setup.
- Local processing mode is not implemented.
- Auto-start at login is not implemented.
- Long recordings are not chunked yet, so latency and API limits need more work.

## 12.3 Next implementation plan

The project is currently at a working MVP prototype stage. Next work should prioritize stabilization before adding major new features.

### Track 1: Testing checklist and validation

Goal: establish a repeatable test matrix so future fixes can be verified consistently.

Checklist:
- Mic-only recording with no Mac output audio.
- System-audio-only recording using browser playback, e.g. YouTube.
- Combined mic + system-audio recording.
- Zoom recording test.
- Google Meet recording test.
- Microsoft Teams recording test.
- Headphones/AirPods vs MacBook speakers.
- Phone-call audio routed through the Mac.
- Short recording under 30 seconds.
- Longer recording over 5 minutes.
- Inactivity auto-stop behavior.

Acceptance criteria:
- Each test has a clear pass/fail result.
- Diagnostics capture enough detail to explain failures.
- Output Markdown is saved in the configured folder for successful tests.

### Track 2: Audio reliability hardening

Goal: make capture and transcription reliable enough for real meetings.

Work items:
- Replace file-size-based system-audio silence detection with real audio-level or waveform analysis.
- Avoid sending empty or silent streams to transcription.
- Improve handling of mid-recording audio route changes, such as headphones, speaker changes, and unplugged devices.
- Add clearer diagnostics for microphone permission, system-audio permission, and capture failures.
- Preserve source-stream metadata so Markdown can explain which streams were captured and which were skipped.

Acceptance criteria:
- Silent system audio does not produce hallucinated transcript text.
- Real system audio is still captured and transcribed.
- Mic capture continues to work independently if system audio fails.

### Track 3: Permission and onboarding UX

Goal: make first-run setup understandable for non-technical users.

Work items:
- Improve the first-run consent and permission checklist.
- Explain why Accessibility permission is needed for double-tap Command.
- Explain microphone and system-audio/screen-capture permissions separately.
- Keep manual menu-bar recording available when shortcut permission is missing.
- Add clearer recovery instructions when macOS permissions are denied or stale.

Acceptance criteria:
- A new user can understand what permissions are required and why.
- The app clearly distinguishes optional shortcut permission from required recording permissions.
- Permission state can be refreshed without restarting when possible.

### Track 4: Production app packaging

Goal: move from development `.app` bundle to a realistic distributable Mac app.

Work items:
- Create a proper macOS app bundle target or repeatable packaging pipeline.
- Add app icon, bundle identifier, versioning, and usage descriptions.
- Sign and eventually notarize the app.
- Reduce confusing Keychain prompts through stable signing identity and bundle metadata.
- Add launch-at-login support after the app bundle is stable.

Acceptance criteria:
- Users can launch AutoScribe as a normal Mac app.
- AutoScribe appears cleanly in macOS permission lists.
- The app can be shared for testing without requiring `swift run`.

### Track 5: Output quality improvements

Goal: make generated notes more consistently useful.

Work items:
- Improve Markdown template formatting.
- Improve meeting title generation and filename cleanup.
- Handle very short or empty recordings gracefully.
- Make summary depth visibly affect output.
- Consider merging mic/system transcripts into a more readable timeline while preserving source labels.

Acceptance criteria:
- Output is readable without manual cleanup for common meeting recordings.
- Short tests do not produce misleading summaries.
- Transcript and summary remain easy to cross-check.

### Track 6: Processing scalability

Goal: support longer real-world meetings without brittle API behavior.

Work items:
- Add chunked transcription for long recordings.
- Add processing progress indicators.
- Handle API rate limits and retryable network failures.
- Track approximate API cost per recording duration.
- Keep local processing as a later track after API MVP stability.

Acceptance criteria:
- Long recordings process without hitting obvious file-size or timeout issues.
- Users get useful progress/error feedback during processing.
- Failed processing does not lose the raw temporary recording until recovery is possible.

## 13) Open questions

- Should inactivity auto-stop be based on silence, no system audio, or both?
- Is "double Command" the final shortcut, or should users configure any global hotkey after MVP?
- Should we store raw audio long-term or delete by default after transcript generation?
- Do we require speaker diarization in MVP or treat it as best-effort?
- Which OpenAI transcription/summarization models should be used for cost/quality tuning?
- What minimum Mac hardware should local mode officially support?
- What is the right production onboarding copy for Accessibility, microphone, and system audio permissions?

## 14) MVP definition (ship criteria)

AutoScribe MVP is ready when:
- User can start/stop recording from global shortcut or menu bar
- App reliably captures mic + system audio in common meeting apps
- App auto-stops after configurable inactivity timeout
- Transcript + summary Markdown file is generated and saved successfully
- User can choose API mode and complete processing end-to-end
- Basic compliance warning and recording-state visibility are in place

## 15) Distribution and go-to-market recommendation

This section captures the recommended path for distributing and marketing AutoScribe. It supersedes the informal "open source vs. share privately" framing.

### 15.1 Key constraint

The processing pipeline splits into two very different steps, and they should not be treated the same way:

- Transcription (audio to text) is the expensive, high-volume step and requires a speech model (OpenAI Whisper today). Anthropic/Claude has no speech-to-text API, and "Codex" is a coding agent, not a transcription service.
- Summarization (text to notes) is cheap and provider-agnostic; OpenAI, Claude, Gemini, or a local model can all do it.

Implication: "let users log in with Claude/Codex" does not map onto what the app does. There is also no consumer OAuth that lets a third-party app bill transcription against someone's ChatGPT or Claude subscription. The only realistic bring-your-own-key (BYOK) flow is pasting an API key, which the app already supports for OpenAI.

Therefore the prior decision before any distribution model is: where does transcription run?

- Keep it on OpenAI Whisper (per-minute cost, mandatory key), or
- Move it on-device (whisper.cpp, or Apple `SpeechTranscriber`/`SpeechAnalyzer` on macOS 26). On-device transcription is free, private, needs no key, and removes the biggest cost and liability driver. BYOK then only matters for the cheap summary step.

### 15.2 Evaluation of the two distribution options

Option B — own API key, shared privately with friends:
- Good only for fast validation; zero friction for testers, quick feedback.
- Do not bake the API key into a distributed `.app` bundle; it is trivially extractable and the account can be drained. If used, keep the key behind a small rate-limited proxy or hand-install on each machine and accept paying their usage.
- Does not scale and has no revenue path. This is a testing phase, not a strategy.

Option A — open source on GitHub, BYOK:
- Best long-term: zero cost to maintainer, no liability for user API spend, infinite scale, developer credibility, and a natural privacy story.
- Frictions to plan for:
  - Audience filter: "get an OpenAI API key" excludes non-technical users; on-device transcription softens this a lot.
  - Distribution: unsigned Mac apps hit Gatekeeper; signing/notarization (Track 4) is not done.
  - Legal/consent: BYOK and/or on-device means the maintainer never touches user audio, which is a selling point, not just a cost saver.

### 15.3 Recommended sequence

1. Now: use Option B privately with a few friends to validate note quality and capture reliability across Zoom/Meet/Teams. Own key, hand-installed, no public binary.
2. Before any public launch: move transcription on-device (Apple `SpeechAnalyzer` or `whisper.cpp`). Highest-leverage change: removes cost, removes the mandatory key, and creates the privacy differentiator versus Otter/Fireflies/Granola.
3. Then open source (Option A) with on-device transcription by default, optional BYOK for a cloud summary (OpenAI or Claude, swappable), and a signed/notarized release so non-developers can run it.

### 15.4 Positioning

Target hook once transcription is on-device: "On-device meeting notes for any Mac call — works on Zoom, Meet, Teams, or a phone call, and your audio never leaves your machine." This is sharper than "another transcriber where you bring an OpenAI key."

### 15.5 Engineering prerequisites (shared by both paths)

- Abstract the summarization provider so OpenAI and Claude are swappable behind `ProcessingProvider`.
- Add an on-device transcription path alongside the existing OpenAI provider.
- Complete production packaging (signing/notarization) from Track 4 before public distribution.

### 15.6 Open go-to-market questions

- Target user: privacy-conscious individuals vs. a broad prosumer crowd (decides how hard the on-device + open-source bet is worth making).
- End state: revenue product vs. portfolio/reputation project (decides whether open-source BYOK is the destination or just a beachhead).

---

## 16. DMG Distribution Plan

### 16.1 Goal

Ship a single `.dmg` file that any Mac user can download, drag to Applications, and run immediately — no downloads, no setup, no API keys. Models ship bundled inside the app.

### 16.2 DMG layout

```
AutoScribe.dmg
├── AutoScribe.app
│   └── Contents/
│       └── Resources/
│           ├── models/
│           │   ├── whisper-base.en/        ← bundled WhisperKit CoreML model
│           │   └── qwen2.5-0.5b-4bit/     ← bundled Qwen MLX weights
│           └── mlx-swift_Cmlx.bundle      ← pre-compiled Metal shaders
└── Applications/                           ← symlink (standard DMG pattern)
```

### 16.3 User experience

1. Download DMG (~500 MB total)
2. Drag to Applications
3. Open — works immediately, offline, no setup

### 16.4 "Update model" option in Settings

- Show the currently active model and its version
- Let users download a larger model (e.g. Whisper `small`, Qwen `1.5B`) for better quality
- App always falls back to the bundled model if a custom one is not present

### 16.5 Engineering requirements

1. **Apple Developer account** ($99/year) — required for notarization so Gatekeeper does not block the app on first launch
2. **Provisioning profile** — unlocks `com.apple.developer.foundation-models.inference` entitlement for Apple Intelligence on macOS 26+
3. **Bundle models at build time** — copy model files into `AutoScribe.app/Contents/Resources/models/` during the release build; update `checkIfDownloaded` / `persistedFolderURL` to check the bundle path as a fallback before the user download cache
4. **DMG creation script** — `create-dmg` or `hdiutil` to produce a signed, notarized `.dmg` with background image and Applications symlink
5. **Model update check** — optional background check for newer bundled model versions; prompt user to download upgrade if available

### 16.6 Execution order (deferred)

1. Obtain Apple Developer account and certificate
2. Add bundled-model fallback path to `WhisperKitTranscriptionService` and `LocalSummarizationService`
3. Write release build script that copies models into the app bundle
4. Notarize and create DMG
5. Add "Update model" UI to Settings

---

## 17. Resource Usage Monitoring

### 17.1 Goal

Show the user real-time memory and CPU usage while the app is recording or processing, so they can see the cost of on-device AI and catch runaway resource usage early.

### 17.2 What to monitor

| Metric | When | Why |
|---|---|---|
| RAM (RSS) | During recording and processing | On-device models use 300–800 MB; warn if system is low |
| CPU % | During transcription and summarization | CPU-only Whisper inference can pin a core for 5–30s |
| Processing time | After each recording | Helps user decide if they need a smaller/larger model |
| Peak memory | After processing completes | Shown in the session summary |

### 17.3 UX

- Small live indicator in the popover (e.g. "RAM: 340 MB | CPU: 42%") visible during Processing state
- After processing completes, show a one-line summary: "Transcribed in 8s · Summarized in 12s · Peak RAM 410 MB"
- Warn (non-blocking toast) if system free RAM drops below 1 GB during processing

### 17.4 Implementation notes

- Use `task_info()` (mach) or `ProcessInfo` for CPU and RSS
- Already have a `ResourceMonitor.swift` stub in the codebase — extend it
- Log metrics to the existing diagnostics panel for debugging

---

## 18. Platform Support

### 18.1 Current: macOS only

AutoScribe is macOS-exclusive. Every layer of the stack depends on Apple-only frameworks:

| Component | Framework | Apple-only? |
|---|---|---|
| System audio capture | `ScreenCaptureKit` | Yes — macOS 12.3+ |
| Microphone recording | `AVFoundation` | Yes |
| Whisper transcription | `WhisperKit` + `CoreML` | Yes — Apple Silicon |
| LLM summarization | `MLX` + Metal shaders | Yes — Apple Silicon |
| Menu bar UI | `AppKit` + `NSStatusItem` | Yes — macOS |
| Apple Intelligence | `FoundationModels` | Yes — macOS 26+ |

### 18.2 Windows — not feasible as a port

A Windows version would be a complete rewrite, not a port. Equivalent Windows stack:

| Component | Windows equivalent |
|---|---|
| System audio | WASAPI loopback capture |
| Transcription | whisper.cpp + DirectML or ONNX Runtime |
| LLM inference | llama.cpp or ONNX Runtime |
| UI | WinUI 3, Electron, or Tauri |

This is a separate product with a separate codebase. Swift code cannot be reused. Not in scope.

### 18.3 iOS / iPadOS — possible but limited

- `AVFoundation` and `CoreML` are available
- `ScreenCaptureKit` is iOS 17+ but system audio capture from other apps is heavily restricted
- No menu bar — would need a different UX (e.g. a floating button or Lock Screen widget)
- MLX works on iPhone 15 Pro+ (A17 Pro) and all M-chip iPads
- Feasible as a future companion app, not a port

### 18.4 Minimum Mac requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| macOS | 14.0 (Sonoma) | 26.0 (for Apple Intelligence) |
| Chip | Apple Silicon (M1+) | M2+ for faster MLX inference |
| RAM | 8 GB | 16 GB (headroom for large models) |
| Storage | 1 GB free | 2 GB (room for model upgrades) |
