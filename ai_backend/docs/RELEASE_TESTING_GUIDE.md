# VoiceGuard Release Testing Guide

We use this guide before giving the application to device testers.

## Local Simulation

From the backend folder:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\voiceguard\ai_backend
python tests\release_readiness.py
```

The script uses held-out real, cloned, and different-speaker audio from `aiworks`.
It also creates a noisy band-limited version to approximate phone-call audio.

It checks:

```text
enrollment
ECAPA voiceprint creation
CNN + LSTM secondary voiceprint creation
same-speaker verification
phone-like same-speaker verification
different-speaker rejection
clone rejection
silence handling
not-enrolled handling
HTTP signaling call, answer, and end flow
```

The report is written to:

```text
ai_backend\docs\RELEASE_READINESS_REPORT.md
```

## What This Cannot Prove

Computer simulation cannot prove Android device audio capture behavior.

We must still test:

```text
VoIP remote audio capture on multiple phones
cellular call audio capture on multiple phones
microphone permissions
audio routing through earpiece, speaker, and Bluetooth
echo cancellation behavior
background and locked-screen behavior
network changes
notifications
```

## Device-Test Gate

We only call the build ready for device testing when:

```text
local readiness script passes
backend starts successfully
Flutter tests pass
Flutter analysis has no blocking errors
debug APK builds successfully
both phones reach the backend
```
