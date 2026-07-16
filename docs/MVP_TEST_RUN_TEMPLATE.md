# MeetingNotes MVP Test Run

Copy this template for each validation pass. Use `docs/MVP_VALIDATION_CHECKLIST.md` for scenario steps.

## Run Metadata

- Date:
- Tester:
- App commit SHA:
- Build command used: `./scripts/build-dev-app.sh`
- Launch command used: `open .build/MeetingNotes.app`
- macOS version:
- Mac model/chip:
- Audio input device:
- Audio output route:
- Headphones/speakers/Bluetooth:
- Output folder:
- Processing mode: Local/Groq API
- Local models downloaded, if selected:
- Groq API key stored in Keychain, if selected: Yes/No
- Groq models observed/configured:

## Permission Status

- Consent checklist accepted: Yes/No
- Microphone permission granted: Yes/No
- Screen & System Audio Recording permission granted: Yes/No
- Keychain prompt shown: Yes/No
- Notes:

## Summary

- Overall result: Pass/Fail/Partial
- Highest severity issue:
- Generated Markdown files:
  - 
- Follow-up bugs/tasks:
  - 

## Scenario Results

| ID | Scenario | Result | Markdown Path | Notes |
| --- | --- | --- | --- | --- |
| 1 | Mic-only recording | Not Run |  |  |
| 2 | System-audio-only browser playback | Not Run |  |  |
| 3 | Combined mic + system audio | Not Run |  |  |
| 4 | Zoom | Not Run |  |  |
| 5 | Google Meet | Not Run |  |  |
| 6 | Microsoft Teams | Not Run |  |  |
| 7 | Headphones vs MacBook speakers | Not Run |  |  |
| 8 | Phone-call audio routed through Mac | Not Run |  |  |
| 9 | Short recording under 30 seconds | Not Run |  |  |
| 10 | Longer recording over 5 minutes | Not Run |  |  |
| 11 | Inactivity auto-stop | Not Run |  |  |

## Scenario Detail

### Scenario 1: Mic-Only Recording

- Result:
- Markdown path:
- Expected transcript present: Yes/No
- Unexpected system-audio text: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 2: System-Audio-Only Browser Playback

- Result:
- Markdown path:
- System audio transcribed: Yes/No
- Microphone leakage observed: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 3: Combined Mic And System Audio

- Result:
- Markdown path:
- Microphone transcribed: Yes/No
- System audio transcribed: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 4: Zoom

- Result:
- Markdown path:
- Remote audio captured: Yes/No
- Local audio captured: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 5: Google Meet

- Result:
- Markdown path:
- Remote audio captured: Yes/No
- Local audio captured: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 6: Microsoft Teams

- Result:
- Markdown path:
- Remote audio captured: Yes/No
- Local audio captured: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 7: Headphones Vs MacBook Speakers

- Result:
- Speaker route result:
- Headphone route result:
- Markdown paths:
- Diagnostics copied: Yes/No
- Notes:

### Scenario 8: Phone-Call Audio Routed Through Mac

- Result:
- Markdown path:
- Remote call audio captured: Yes/No
- Local audio captured: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 9: Short Recording Under 30 Seconds

- Result:
- Markdown path:
- No fake decisions/action items: Yes/No
- Diagnostics copied: Yes/No
- Notes:

### Scenario 10: Longer Recording Over 5 Minutes

- Result:
- Markdown path:
- Processing duration:
- API or timeout issues:
- Diagnostics copied: Yes/No
- Notes:

### Scenario 11: Inactivity Auto-Stop

- Result:
- Timeout configured:
- Auto-stop observed: Yes/No
- Markdown path:
- Diagnostics copied: Yes/No
- Notes:

## Copied Validation Report

Paste the app's copied validation report here.

```text

```

## Copied Diagnostics

Paste raw diagnostics here if different from the validation report.

```text

```
