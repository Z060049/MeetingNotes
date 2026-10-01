# MeetingNotes

**One universal raw transcript for any meeting app.**

MeetingNotes is a macOS menu-bar app that records your microphone and system audio, then creates one raw Markdown transcript using Groq.
## Demo

![MeetingNotes demo](docs/meetingnotes-demo.gif)

## Why MeetingNotes

Most teams switch between Zoom, Google Meet, Microsoft Teams, and other tools depending on the situation. Sometimes recording is disabled by the host. Sometimes the meeting platform simply doesn't offer it. MeetingNotes solves this at the system level — it captures your microphone and your Mac's audio output simultaneously, regardless of which app is playing the audio.

It doesn't integrate with any meeting platform. It doesn't need to. It records what your Mac hears.

## Privacy

- Audio is sent to Groq for transcription with `whisper-large-v3-turbo`.
- Your Groq API key is stored in macOS Keychain.
- MeetingNotes does not generate or send a summary.
- The resulting raw transcript is saved in your selected local output folder.

## Legal notice — recording consent

**You are responsible for complying with the recording laws of every jurisdiction involved in your call.**

MeetingNotes is a system-level audio capture tool. It cannot verify whether the people you are recording have consented. Recording a conversation without the other participants' knowledge or consent may be a criminal offence depending on where you and they are located.

### One-party vs. all-party consent

Most countries divide into two camps:

- **One-party consent** — you can record a conversation you are a participant in without telling the other person. United States federal law, Canada, and the UK follow this rule as a baseline.
- **All-party (two-party) consent** — *every* person on the call must be informed and consent before you start recording. Recording without this is a criminal offence.

### Where all-party consent applies (as of 2026)

**United States — 12 states require all-party consent:**
California, Connecticut, Delaware, Florida, Illinois, Maryland, Massachusetts, Michigan, Montana, New Hampshire, Pennsylvania, and Washington.

If any participant on your call is located in one of these states, that state's law likely applies to the whole call — even if you are calling from a one-party state.

**Australia — all-party consent required in:**
New South Wales, South Australia, Western Australia, Tasmania, and the ACT. Penalties include up to 5 years imprisonment in NSW.

**European Union:** GDPR requires transparency — participants must be informed that a call is being recorded. Many EU member states additionally treat covert recording as a criminal offence.

### Other jurisdictions

| Country | Rule | Notes |
|---|---|---|
| Canada | One-party (federal) | Quebec has stricter GDPR-style rules. Recording a call you are not part of is a federal crime. |
| UK | One-party (personal use) | Sharing the recording outside the call requires consent. GDPR applies for professional use. |
| Australia (QLD, VIC, NT) | One-party | Recording permitted; sharing may require all-party consent. |

### The safe rule

**Tell everyone on the call that you are recording before you start.** This satisfies the consent requirement in virtually every jurisdiction and eliminates legal ambiguity entirely. MeetingNotes's built-in consent reminder (enabled by default in Settings) is designed to help you build this habit.

## Requirements

| | Minimum | Recommended |
|---|---|---|
| macOS | 14 (Sonoma) | Latest macOS |
| Chip | Apple Silicon (M1+) | M2+ |
| RAM | 8 GB | 8 GB+ |

The current build script produces an Apple Silicon app.

## Transcription

MeetingNotes uses Groq-hosted Whisper. Add a `GROQ_API_KEY` during onboarding; no local model download is required.

## Output

Each recording saves a single Markdown file to `~/Documents/MeetingNotes/`:

```
2026-07-13_14-30_recording_transcript.md
```

The file contains:
- Metadata (date, duration, audio sources captured)
- The unmodified transcript with `Microphone` and `System Audio` labels

No summary, title generation, action items, or second notes file is produced.

## Build and run

```sh
./scripts/build-dev-app.sh
open build/MeetingNotes.app
```

On first launch, grant the following permissions when prompted:

| Permission | Purpose |
|---|---|
| Microphone | Capture your voice |
| Screen & System Audio Recording | Capture audio from Zoom, Meet, Teams, or any other app |

MeetingNotes opens a guided setup window on first launch. Add your `GROQ_API_KEY`; it is stored securely in macOS Keychain. Groq offers a rate-limited free tier.

Enable Microphone access, then enable MeetingNotes under **System Settings → Privacy & Security → Screen & System Audio Recording**. macOS requires MeetingNotes to restart after the second permission is enabled; the setup window provides a restart button and verifies access on the next launch.

Only these two permissions are required. MeetingNotes does not request Camera, Accessibility, or System Audio Recording Only access.

Recording is started and stopped from the menu bar.

## Settings

| Setting | Default |
|---|---|
| Transcription provider | Groq API |
| Speech model | `whisper-large-v3-turbo` |
| Prompt to stop after silence | On, after 180 seconds |
| Output folder | `~/Documents/MeetingNotes/` |
| Consent reminder | On |

## Test

```sh
swift test
```

## Diagnostics and recovery

Logs are written to `~/Library/Logs/MeetingNotes/MeetingNotes.log`.

If the app exits unexpectedly during a recording, the audio is preserved in `~/Library/Application Support/MeetingNotes/Recording Recovery/` and reported at next launch.

## Status

Groq transcription and raw Markdown export work end-to-end. The current distributable is a development build — production packaging (code signing, notarization) is not yet complete. See `PRD.md` for the full roadmap.
