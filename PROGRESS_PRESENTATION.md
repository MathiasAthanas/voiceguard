# VoiceGuard Progress Presentation

## 1. Project Overview

VoiceGuard is a Flutter mobile application with a Python AI backend for voice identity verification during calls.

The project currently focuses on:

- Enrolling a person's voiceprint.
- Detecting whether a live caller sounds like the enrolled contact.
- Detecting possible AI-generated or cloned voices when anti-spoofing weights are available.
- Supporting VoIP calls through WebRTC.
- Supporting cellular-call monitoring and verification where Android allows it.
- Making local testing reliable across multiple phones on the same network.

## 2. Current Architecture

The project has three main parts:

- `app/` - Flutter Android application.
- `ai_backend/` - Python FastAPI backend for AI verification and now local signaling.
- `server/` - Older Node Socket.IO signaling server, kept in the repo but no longer required for the new local flow.

The current recommended local setup is:

```text
Flutter app
  -> http://PC_IP:8000/health
  -> http://PC_IP:8000/enroll
  -> http://PC_IP:8000/verify
  -> ws://PC_IP:8000/signaling/ws/{userId}
  -> http://PC_IP:8000/signaling/events/{userId} fallback

FastAPI backend
  -> AI enrollment
  -> AI verification
  -> WebSocket signaling
  -> HTTP long-poll signaling fallback
```

## 3. What We Started With

Earlier local development used two servers:

- Python AI backend on port `8000`.
- Node Socket.IO signaling server on port `3000` or `9000`.

This worked on some devices, but other phones could reach the Python backend while failing to reach the Node signaling server from the app.

The confusing part was that a mobile browser could sometimes open the Node server URL, but the Flutter app still failed to connect. We confirmed this was because browser HTTP reachability is not the same as app WebSocket reachability.

## 4. Main Problem We Investigated

The practical issue was:

```text
Some mobile devices could reach the Python backend,
but the app could not complete signaling through the Node WebSocket server.
```

Important findings:

- The Python FastAPI backend was reachable from the affected phones.
- The Node HTTP root endpoint could be reachable in a browser.
- Socket.IO polling could return a valid session response in the browser.
- The Flutter mobile app still timed out when using WebSocket signaling.
- Developer Options being disabled was not the root cause.
- A release APK can preserve old local settings, but that was checked and ruled out for the reported devices.

The conclusion was that the local WebSocket path to Node was unreliable across the test phones and network conditions.

## 5. Networking Improvements Completed

We added better Node server diagnostics first:

- Node now prints available LAN URLs at startup.
- Node logs the transport used by connected clients.
- This helped confirm when a phone actually connected by WebSocket.

Then we moved to the stronger local solution:

- FastAPI now has a `/signaling` API.
- The Flutter app can try FastAPI WebSocket first.
- If WebSocket fails, the Flutter app falls back to HTTP long polling.
- The app can now use one local backend URL for both AI and signaling.

Current app setting recommendation:

```text
Signaling Server URL: http://YOUR_PC_IP:8000
AI Backend URL:       http://YOUR_PC_IP:8000
```

## 6. FastAPI Signaling Added

New backend file:

```text
ai_backend/app/api/signaling.py
```

It supports:

- User registration.
- Online user list.
- Incoming call events.
- Call answer events.
- Call rejection events.
- Call ended events.
- ICE candidate exchange.
- WebSocket signaling.
- HTTP long-poll fallback signaling.

FastAPI route group:

```text
/signaling/ws/{user_id}
/signaling/register
/signaling/events/{user_id}
/signaling/call
/signaling/answer
/signaling/reject
/signaling/end
/signaling/ice
/signaling/stats
```

The backend keeps in-memory users, rooms, event queues, and active WebSocket connections.

## 7. Flutter Signaling Rework

The Flutter app now uses:

- Dart `WebSocket` for the first signaling attempt.
- Dio HTTP requests for fallback signaling.
- The same existing `SignalingService` public methods, so screens can continue using the same call flow.

Important behavior:

```text
1. App connects to ws://PC_IP:8000/signaling/ws/{userId}
2. If that succeeds, signaling is realtime.
3. If that fails after a short timeout, app registers over HTTP.
4. App then long-polls /signaling/events/{userId}.
```

This keeps the best local experience where WebSocket works, while still allowing problematic devices to function over normal HTTP.

## 8. AI Backend Progress

The AI backend currently provides:

- Health check endpoint.
- Voice enrollment endpoint.
- Voice verification endpoint.
- Voiceprint storage.
- Audio preprocessing.
- Speech detection for silent audio rejection.
- ECAPA-TDNN speaker embedding and verification.
- AASIST anti-spoofing hook when model weights are available.

Verification behavior includes:

- Rejecting silent audio.
- Checking whether a contact has a voiceprint.
- Comparing live audio against saved embeddings.
- Returning `verified_high`, `verified`, `uncertain`, `not_verified`, `silent`, `not_enrolled`, or `spoof_detected`.
- Calibrated thresholds for phone-call audio, which is usually noisier and more compressed than clean microphone recordings.

## 9. Current And Planned AI Models

The project currently uses pretrained voice models for the first working version, while we are now training our own models with our own datasets.

This is important because pretrained models are useful for getting the system working, but our own local datasets can improve accuracy for the real voices, phones, accents, languages, microphones, and call conditions we expect VoiceGuard to handle.

### Models Used Right Now

Current backend model pipeline:

- `ECAPA-TDNN` for speaker verification.
- `AASIST` for anti-spoofing when the required model weights are available.
- Audio preprocessing and speech detection before verification.

### ECAPA-TDNN

ECAPA-TDNN is currently used for speaker identity verification.

How it works in VoiceGuard:

1. During enrollment, the backend receives one or more voice samples.
2. ECAPA-TDNN converts each sample into a speaker embedding.
3. If there are multiple samples, the backend averages the embeddings.
4. The final embedding is saved as that contact's voiceprint.
5. During a call, the backend extracts an embedding from the live audio segment.
6. The live embedding is compared with the saved contact voiceprint.
7. The backend returns a similarity score and a verdict such as `verified`, `uncertain`, or `not_verified`.

Why we use it:

- It is strong for speaker recognition.
- It gives compact speaker embeddings.
- It lets us compare enrolled and live voices without retraining for every new contact.

### AASIST

AASIST is currently used as the anti-spoofing model hook.

How it works in VoiceGuard:

1. The backend splits audio into usable speech segments.
2. AASIST analyzes whether the audio looks genuine or spoofed.
3. If spoof probability is high, the backend can return `spoof_detected`.
4. If anti-spoofing weights are not available, the backend continues with speaker verification and reports that anti-spoofing is unavailable.

Why we use it:

- It is designed for detecting spoofed, replayed, synthetic, or AI-generated speech patterns.
- It gives VoiceGuard a second layer of protection beyond speaker similarity.

### CNN Model Direction

We are now training CNN-based models with our own datasets.

How the CNN will help:

- The CNN will learn patterns from spectrogram-style audio features.
- It can detect local voice characteristics and acoustic patterns from our dataset.
- It is useful for classifying whether a segment belongs to the expected speaker, another speaker, or a suspicious/generated voice class.
- It can improve accuracy on local languages, accents, microphones, and phone-call audio quality.

Expected CNN flow:

```text
audio segment
  -> preprocessing
  -> spectrogram / log-mel features
  -> CNN feature extraction
  -> classification or confidence score
  -> final verification decision
```

### LSTM Model Direction

We are also training LSTM-based models with our own datasets.

How the LSTM will help:

- The LSTM will learn how voice features change over time.
- It can capture speaking rhythm, timing, and sequence patterns.
- It is useful because a caller's identity is not only in one audio frame, but also in how their voice evolves across a phrase or call segment.
- It can improve decisions on noisy phone audio where a single short feature snapshot is not enough.

Expected LSTM flow:

```text
audio segment
  -> preprocessing
  -> frame-level features over time
  -> LSTM sequence learning
  -> speaker or spoof confidence
  -> final verification decision
```

### How CNN And LSTM Fit The Final Direction

The direction is not to throw away the current working pipeline immediately. The direction is to improve it step by step:

1. Keep ECAPA-TDNN and AASIST as the working baseline.
2. Train CNN and LSTM models on our localized datasets.
3. Compare their accuracy against the current baseline.
4. Add the best-performing model or model combination into the backend.
5. Use local test calls to measure real-world accuracy, not only clean recording accuracy.

Possible final AI decision flow:

```text
call audio
  -> speech detection
  -> anti-spoofing check
  -> ECAPA speaker similarity
  -> CNN local-pattern confidence
  -> LSTM time-sequence confidence
  -> combined verdict
```

The goal is better accuracy for our actual environment, especially where generic pretrained models may not fully understand local voices, accents, languages, and call audio conditions.

## 10. Flutter App Progress

The app currently includes:

- Home screen and setup flow.
- Settings screen for backend URLs and verification sensitivity.
- Enrollment screen for recording voice samples.
- Dialer and VoIP screens.
- In-call screen with call controls.
- Contact and history areas.
- Verification overlay during calls.
- Confidence chart/history.
- Call record storage with Hive.
- WebRTC audio call setup.
- DTMF support.
- Mute, speaker, answer, reject, and end-call controls.

The app also has call-time voice verification logic:

- It records call audio segments.
- It sends segments to the AI backend.
- It smooths verification results across a rolling window.
- It avoids flipping the UI based on one noisy segment.

## 11. Audio And Call Handling Progress

Work completed around audio/calls includes:

- WebRTC local audio stream setup.
- Opus SDP tuning for speech.
- ICE candidate buffering until remote description is ready.
- Native Android speaker routing through a method channel.
- Cellular call service integration.
- Separate recording paths for VoIP and cellular verification.
- VAD processing to extract useful remote-speaker audio.
- Call-time enrollment mode for gathering samples during calls.

This matters because phone-call audio is much harder than normal microphone enrollment. It is compressed, noisy, sometimes echo-cancelled, and often mixed with local audio.

## 12. Documentation Added

New file:

```text
IMPROVEMENTS.md
```

It explains:

- What changed from the two-server setup.
- Why the Node WebSocket path was unreliable locally.
- Why FastAPI now handles AI and signaling.
- How to pull the latest code.
- How to install Python dependencies.
- How to install Flutter dependencies.
- How to start the backend.
- How to find the PC IP address.
- What URLs to use in the app.
- How to build a standard obfuscated APK.

This file is meant for teammates who need simple instructions without needing to understand the full codebase.

## 13. APK Build Completed

An obfuscated universal release APK was built with:

```powershell
flutter build apk --release --obfuscate --split-debug-info=build\debug-info
```

Generated APK:

```text
app/build/app/outputs/flutter-apk/app-release.apk
```

The release APK size reported by Flutter was about:

```text
80.9 MB
```

## 15. Verification Completed

Checks completed:

- Python syntax check for new backend files passed.
- FastAPI signaling hub was tested in-process for registration and call event routing.
- `flutter pub get` completed successfully.
- Socket.IO packages were removed from Flutter dependency lockfile during local app dependency refresh.
- Targeted Dart analysis for the new signaling service passed.
- Debug APK build previously succeeded.
- Obfuscated release APK build succeeded.
- Backend signaling commit pushed to GitHub.

Known analyzer status:

- Full `flutter analyze` still reports older unrelated warnings and deprecation notes in existing app files.
- The new signaling service itself analyzed cleanly.

## 16. Current Direction

The local-development direction is:

```text
One FastAPI backend on port 8000.
WebSocket first.
HTTP long-polling fallback.
One URL for both AI and signaling.
```

This gives us the best local balance:

- Realtime when WebSocket works.
- Reliability when WebSocket fails.
- Less confusion from multiple ports.
- No dependency on the old Node server for local testing.

For future production, the stronger direction would be:

- Hosted backend.
- HTTPS and WSS.
- Domain name instead of LAN IP.
- Proper persistent signaling/session storage.
- Push notifications for incoming calls when the app is backgrounded.

The AI-model direction is:

```text
Keep the current ECAPA-TDNN/AASIST baseline.
Train CNN and LSTM models with our own localized datasets.
Compare the models using real local call audio.
Integrate the best-performing model combination into the FastAPI backend.
```

This keeps the system working while we improve accuracy with data that better represents the users and environments VoiceGuard is being built for.

## 18. Summary

So far, VoiceGuard has moved from a split local architecture with unreliable Node WebSocket signaling to a stronger local architecture centered on FastAPI.

We now have:

- AI enrollment.
- AI verification.
- WebRTC call signaling.
- WebSocket-first signaling.
- HTTP fallback for devices where WebSocket fails.
- A clearer local setup guide.
- An obfuscated release APK.
- Backend signaling changes pushed to Git.
- A clear model-improvement direction using localized CNN and LSTM training.
