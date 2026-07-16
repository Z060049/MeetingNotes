# MeetingNotes MVP Validation Checklist

Use this checklist for every manual MVP validation pass. Record results in `docs/MVP_TEST_RUN_TEMPLATE.md`.

## Preflight

- [ ] Build the dev app bundle:

  ```sh
  ./scripts/build-dev-app.sh
  ```

- [ ] Launch the dev app:

  ```sh
  open .build/MeetingNotes.app
  ```

- [ ] Confirm `MeetingNotes` appears in the menu bar.
- [ ] Open MeetingNotes settings and confirm the OpenAI API key is saved.
- [ ] Confirm output folder is set, usually `~/Documents/MeetingNotes/`.
- [ ] Confirm the first-launch onboarding window opens automatically.
- [ ] Confirm microphone permission is granted from the onboarding flow.
- [ ] Confirm Screen & System Audio Recording permission is enabled for `MeetingNotes`; ScreenCaptureKit is the only automatic system-audio backend.
- [ ] Confirm onboarding requires a restart after system-audio access is requested.
- [ ] Confirm the restarted app verifies both permissions and reaches the Ready screen.
- [ ] Confirm recording is blocked with a Finish Setup action if either permission is revoked.
- [ ] No camera or Accessibility permission is required for audio capture.
- [ ] Confirm the Debug section is visible and diagnostics can be copied.
- [ ] Clear diagnostics before each scenario unless the test requires preserving prior state.

## Pass/Fail Rules

A scenario passes when:
- MeetingNotes reaches `Complete`.
- A Markdown file is saved to the configured output folder.
- The Markdown metadata has the expected duration, processing mode, and audio sources.
- Transcript content matches the expected source streams.
- Diagnostics explain the path taken, including file sizes, stream transcription decisions, and output path.

A scenario fails when:
- MeetingNotes reaches `Error`.
- No Markdown file is generated for a scenario that should complete.
- Silent audio produces misleading transcript content.
- Expected source audio is missing from the transcript.
- Diagnostics are insufficient to explain what happened.

## Scenario 1: Mic-Only Recording

Purpose: verify microphone capture works when no Mac output audio is playing.

Setup:
- Close or pause all apps that could play sound.
- Use MacBook microphone or selected input device.
- Keep speakers/headphones silent.

Steps:
- [ ] Clear diagnostics.
- [ ] Start recording from the menu bar.
- [ ] Speak for 10-20 seconds.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected diagnostics:
- `State changed to Recording.`
- `Audio capture started.`
- `Audio capture stopped.`
- `Microphone file size: ...`
- `System Audio file size: ...`
- `System Audio transcription skipped: ...` if the system stream is silent/tiny.
- `Markdown saved to ...`

Expected Markdown:
- Transcript includes `Microphone:` with spoken text.
- Transcript does not include hallucinated `System Audio:` content.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 2: System-Audio-Only Browser Playback

Purpose: verify system audio capture works independently from microphone speech.

Setup:
- Open a browser video/audio source, such as YouTube.
- Do not speak during recording.
- Set volume to an audible level.

Steps:
- [ ] Clear diagnostics.
- [ ] Start browser playback.
- [ ] Start recording.
- [ ] Let system audio play for 15-30 seconds.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected diagnostics:
- `System Audio file size: ...` shows a meaningful file size.
- System audio is sent to transcription, not skipped.
- `Markdown saved to ...`

Expected Markdown:
- Transcript includes `System Audio:` with content from browser playback.
- Transcript has little or no microphone content unless room audio leaked into the mic.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 3: Combined Mic And System Audio

Purpose: verify dual-stream capture with local voice and remote/system audio together.

Setup:
- Open browser playback.
- Prepare a short phrase to speak over or around playback.

Steps:
- [ ] Clear diagnostics.
- [ ] Start browser playback.
- [ ] Start recording.
- [ ] Speak for 10-20 seconds while audio plays.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected diagnostics:
- Both microphone and system-audio file sizes are present.
- Both streams are sent to transcription when non-silent.
- `Markdown saved to ...`

Expected Markdown:
- Transcript includes `Microphone:` with local speech.
- Transcript includes `System Audio:` with playback content.
- Summary should mention the dominant test content without inventing decisions.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 4: Zoom

Purpose: validate common meeting-app capture.

Setup:
- Use a Zoom test meeting or call with remote audio available.
- Run both startup-order passes below.

Pass A — MeetingNotes first:
- [ ] Clear diagnostics.
- [ ] Start recording in MeetingNotes.
- [ ] Open or join Zoom.
- [ ] Confirm Zoom microphone and speaker controls work normally.
- [ ] Speak locally and play or receive remote audio.
- [ ] Stop recording and wait for processing to complete.

Pass B — Zoom first:
- [ ] Clear diagnostics.
- [ ] Open or join Zoom.
- [ ] Start recording in MeetingNotes.
- [ ] Confirm Zoom microphone and speaker controls work normally.
- [ ] Speak locally and play or receive remote audio.
- [ ] Stop recording and wait for processing to complete.

Expected Markdown:
- Local voice appears under `Microphone:`.
- Remote meeting audio appears under `System Audio:` if routed through Mac output.
- Diagnostics identify ScreenCaptureKit as the selected system-audio backend.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 5: Google Meet

Purpose: validate browser-based meeting capture.

Setup:
- Join a Google Meet test call.
- Confirm remote audio is audible through the Mac.

Steps:
- [ ] Clear diagnostics.
- [ ] Start recording.
- [ ] Speak locally.
- [ ] Play or receive remote audio.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected Markdown:
- Local voice appears under `Microphone:`.
- Remote meeting audio appears under `System Audio:`.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 6: Microsoft Teams

Purpose: validate Teams meeting capture.

Setup:
- Join a Teams test call.
- Confirm remote audio is audible through the Mac.

Steps:
- [ ] Clear diagnostics.
- [ ] Start recording.
- [ ] Speak locally.
- [ ] Play or receive remote audio.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected Markdown:
- Local voice appears under `Microphone:`.
- Remote meeting audio appears under `System Audio:`.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 7: Headphones Vs MacBook Speakers

Purpose: validate audio route differences.

Run the combined mic/system test for each route:
- [ ] MacBook speakers.
- [ ] Wired headphones.
- [ ] AirPods mic + AirPods output.
- [ ] AirPods output + MacBook microphone.
- [ ] MacBook output + AirPods microphone, if macOS permits that route.

Expected result:
- Microphone capture works with MacBook microphone and wired microphones.
- AirPods/Bluetooth routes start recording when microphone capture produces buffers.
- System audio capture works when output is routed to speakers or supported headphones, or produces clear diagnostics if route-specific capture fails.
- If system audio capture fails on an AirPods output route, microphone recording continues and diagnostics identify each failed backend.

Result:
- Pass/Fail:
- Markdown paths:
- Notes:

## Scenario 8: Phone-Call Audio Routed Through Mac

Purpose: validate phone or continuity-call workflows.

Setup:
- Route a phone call or test call through Mac audio.

Steps:
- [ ] Clear diagnostics.
- [ ] Start recording.
- [ ] Speak locally.
- [ ] Let remote call audio play through the Mac.
- [ ] Stop recording.
- [ ] Wait for processing to complete.

Expected Markdown:
- Local speech appears under `Microphone:`.
- Remote call audio appears under `System Audio:` if it is routed through Mac output.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 9: Short Recording Under 30 Seconds

Purpose: verify short recordings do not produce misleading summaries or fake decisions.

Steps:
- [ ] Record 5-20 seconds with a simple phrase.
- [ ] Stop and process.

Expected Markdown:
- Summary is brief.
- No fake decisions or action items.
- Transcript is present.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 10: Longer Recording Over 5 Minutes

Purpose: identify latency, file-size, and processing behavior before chunking is implemented.

Steps:
- [ ] Record for more than 5 minutes with periodic speech or audio.
- [ ] Stop and process.

Expected result:
- Recording does not crash.
- Processing either completes or fails with useful diagnostics.
- Temporary recordings are not lost before failure diagnosis if processing fails.

Result:
- Pass/Fail:
- Markdown path:
- Notes:

## Scenario 11: Inactivity Auto-Stop

Purpose: verify automatic stop after configured inactivity timeout.

Setup:
- In Settings, temporarily set inactivity timeout to a short value, such as 30 seconds.

Steps:
- [ ] Clear diagnostics.
- [ ] Start recording.
- [ ] Create a few seconds of audio.
- [ ] Stay silent and stop all system audio.
- [ ] Wait for timeout.

Expected diagnostics:
- `Inactivity timeout reached. Stopping recording.`
- Processing starts after auto-stop.
- Markdown is saved or a clear processing error is shown.

Result:
- Pass/Fail:
- Markdown path:
- Notes:
