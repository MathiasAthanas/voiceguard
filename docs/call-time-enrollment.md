# Call-time auto-enrollment & verification — how it works and why it was stuck

## Symptom

- **Cellular:** auto voice enrollment never completes.
- **VoIP:** the profile bar is stuck at *Building voice profile 0/5*.

## Root cause

Every recorded 5-second segment — on both VoIP and cellular — is passed through
`VadProcessor` before it can count toward enrollment or be verified. When the
VAD returned `null`, the segment was **silently dropped**: the segment handler
never fired, the counter never advanced, and there was no feedback. So "0/5
forever" simply meant the VAD was rejecting every segment.

The VAD was rejecting every segment for a structural reason:

1. **Its core assumption was "the remote caller is the *quiet* part of the mic
   signal" (faint earpiece bleed).** That only holds when the phone is held to
   the ear — and in that mode the earpiece is tiny and aimed at the ear, so
   there is almost no remote audio in the mic to extract.
2. **On speakerphone the opposite is true** — the remote caller is *loud* — and
   the old logic actively discarded exactly those frames.
3. **On cellular, Android forbids a normal app from recording the call
   downlink.** `VOICE_RECOGNITION` only captures the local mic plus acoustic
   bleed, so there is no reliable remote-caller signal unless on speaker.
4. **For VoIP, the second mic capture (`record` package) competes with WebRTC's
   mic ownership**, often yielding empty or local-only audio.

## Fix

### 1. A real VAD mode for enrollment (`vad_processor.dart`)

`VadProcessor` now has two modes:

| Mode | Keeps | Used for |
|------|-------|----------|
| `remoteBleed` | frames *below* the adaptive threshold (quiet earpiece bleed) | held-to-ear cellular **verification** |
| `speech` | every *voiced* frame above the silence floor (a true VAD) | **enrollment** / speakerphone |

Enrollment uses `speech` mode, so on speakerphone — where the caller is loud —
it keeps the caller's speech instead of throwing it away.

### 2. Dead-capture guard + diagnostics

- If the loudest frame in a clip is near silence (`peak < _minPeak`), the clip
  is reported as `silent_capture` instead of emitting a silent WAV the backend
  would reject anyway.
- Every decision now logs `peak`, `threshold`, kept-ms and the skip reason, so
  failures are debuggable from `flutter logs` / `adb logcat`.

### 3. Capture-failure feedback to the UI

`CallAudioRecorder` and `AudioCaptureService` track consecutive skips and fire
`onCaptureIssue(reason)` after 3 in a row (or immediately on a hard
`recorder_unavailable`). `InCallScreen` shows a tappable banner:

> 🔊 Tap to turn on speaker so VoiceGuard can hear the caller.

One tap enables speakerphone, which is the physically reliable capture path.

### 4. VAD/backend duration alignment

The VAD's minimum kept audio (`_minTotalMs = 1300 ms`) is kept **above** the
backend's call-time minimum (`min_duration_seconds = 1.2 s`). Previously a too-
short segment could advance the counter only for the backend to reject every
sample as `too_short` — looking like "stuck" all over again.

## Platform limitation (important)

Reliable call-time capture of the *remote* caller requires **speakerphone**.
Android blocks downlink recording, and earpiece bleed is too faint to enroll
from. The UI now guides the user there automatically rather than failing
silently. For the cleanest profile, put the call on speaker, let the contact
talk, and stay quiet while the bar fills.
