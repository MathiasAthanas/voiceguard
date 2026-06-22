# VoiceGuard Model Operation And Integration Guide

This document explains how the VoiceGuard models work and how we have integrated them into the application together.

Our purpose is to make it easy for someone to understand the complete path:

```text
call audio
-> audio preparation
-> model inference
-> voiceprint comparison
-> final backend verdict
-> mobile feedback and detection history
```

This guide focuses on the models that are connected to the current VoiceGuard system, what each model is responsible for, and how the mobile application and FastAPI backend use them.

## 1. The Two Questions We Need To Answer

VoiceGuard does not solve only one AI problem. We need to answer two different questions.

The first question is:

```text
Does this audio sound real, or does it contain cloned/synthetic voice evidence?
```

This is called:

```text
anti-spoofing or cloned-voice detection
```

The second question is:

```text
Does this voice belong to the person we enrolled for this contact?
```

This is called:

```text
speaker verification
```

These questions are related, but they are not the same.

A real human voice can belong to the wrong person. A cloned voice can also be designed to sound like the correct person. This is why we use separate model signals instead of expecting one score to answer everything.

## 2. Our Current Model Architecture

The current backend pipeline is:

```text
captured remote-speaker audio
-> CNN + LSTM v2 anti-spoofing
-> ECAPA-TDNN primary speaker verification
-> CNN + LSTM speaker embedding secondary verification
-> final verdict
```

The responsibilities are:

| Model | Full role | Current responsibility |
| --- | --- | --- |
| CNN + LSTM v2 | Convolutional Neural Network plus Long Short-Term Memory network | Produces real/cloned risk probabilities |
| ECAPA-TDNN | Emphasized Channel Attention, Propagation and Aggregation in a Time-Delay Neural Network | Primary comparison against the enrolled speaker |
| CNN + LSTM speaker embedding | Convolutional Neural Network plus Long Short-Term Memory embedding network | Secondary comparison against our locally trained voiceprint |

The primary model is currently ECAPA-TDNN because it produced the strongest speaker-verification result in our comparison.

## 3. Audio Preparation Before Any Model Runs

The models do not receive arbitrary phone audio directly.

The backend first prepares the audio through:

```text
voiceguard/ai_backend/app/services/audio_processor.py
```

The common preparation is:

```text
decode the uploaded audio
convert it to 16 kHz
convert it to one channel
normalize the waveform
check for speech
split verification audio into 3-second segments
```

The anti-spoofing and local speaker models then convert audio into log-mel spectrograms using:

```text
sample rate: 16000 Hz
clip length: 4 seconds
mel bands: 64
FFT size: 400
hop length: 160
frequency range: 20 Hz to 7600 Hz
```

A log-mel spectrogram represents:

```text
frequency on one axis
time on the other axis
sound energy as the values
```

This gives the neural networks a structured view of how the voice behaves across frequency and time.

## 4. How Our CNN + LSTM V2 Anti-Spoofing Model Works

The model file is loaded through:

```text
voiceguard/ai_backend/app/models/cnn_lstm_voiceguard.py
```

The trained checkpoint is expected at:

```text
aiworks/models/cnn_lstm_v2/best_model.pt
```

The anti-spoofing model receives a log-mel feature with a shape similar to:

```text
1 channel x 64 mel bands x time frames
```

The CNN layers learn local patterns such as:

```text
unnatural frequency textures
spectral smoothing
repeated synthesis artifacts
unusual energy transitions
```

The LSTM then studies how those features change over time.

This matters because a cloned voice may look realistic in a short instant while still producing unnatural temporal behavior across a longer section.

The final classifier produces two probabilities:

```text
real_probability
spoof_probability
```

The currently configured anti-spoofing threshold is:

```text
CNN_LSTM_SPOOF_THRESHOLD=0.32
```

This means the model's internal decision is:

```text
spoof probability >= 0.32 -> cloned
spoof probability < 0.32  -> real
```

The backend averages the spoof probabilities from all usable segments before returning the anti-spoofing result.

## 5. Important Current Anti-Spoofing Behavior

The CNN + LSTM v2 model is integrated and runs during verification.

However, we currently use its result as:

```text
risk telemetry
```

It does not currently override the final speaker-verification verdict.

We made this decision because real phone-call audio produced anti-spoofing false positives. A genuine caller could receive a high cloned-voice score because of:

```text
telephone compression
speakerphone echo
background noise
low microphone level
codec artifacts
mixed local and remote audio
```

The spoof probability is still returned to the app, stored in history, and shown on the dashboard. Before we use it as a blocking decision again, we need to calibrate it using real call audio captured through the same mobile pipeline.

## 6. How ECAPA-TDNN Speaker Verification Works

ECAPA-TDNN is our primary speaker-verification model.

Its purpose is not to identify cloned audio directly. Its purpose is:

```text
audio -> speaker embedding
```

A speaker embedding is a numerical vector that represents speaker characteristics learned from the voice.

During enrollment, ECAPA converts each accepted sample into an embedding. We average several accepted embeddings and normalize the result. This becomes the saved ECAPA voiceprint.

During verification, ECAPA converts the new call audio into another embedding and calculates cosine similarity:

```text
saved enrollment embedding
compared with
new call embedding
```

The current configured primary threshold is:

```text
VERIFICATION_THRESHOLD=0.55
```

The current interpretation is:

```text
similarity >= 0.55 -> primary speaker match
similarity < 0.55  -> primary speaker mismatch
```

A similarity of `0.55` should not be described as guaranteed identity. It is an operating threshold selected for phone and VoIP audio, where channel differences reduce similarity.

## 7. Why ECAPA Is Still Our Primary Model

We compared ECAPA and our CNN + LSTM speaker embedding model using the same test pairs.

The test results were:

| Model | Accuracy | Same-speaker recall | Different-speaker rejection | Clone-attack rejection |
| --- | ---: | ---: | ---: | ---: |
| CNN + LSTM speaker embedding | 83.02% | 72.81% | 88.12% | 83.13% |
| ECAPA-TDNN | 98.75% | 96.25% | 100.00% | 100.00% |

This told us:

```text
ECAPA is currently the strongest identity signal in VoiceGuard.
```

We therefore kept it as the primary model instead of replacing it only because our local model uses CNN and LSTM.

## 8. How Our CNN + LSTM Speaker Embedding Model Works

Our local speaker model is also loaded through:

```text
voiceguard/ai_backend/app/models/cnn_lstm_voiceguard.py
```

Its checkpoint is expected at:

```text
aiworks/models/speaker_embedding/best_model.pt
```

This model does not output `real` or `cloned` classes.

It outputs a normalized embedding vector:

```text
audio -> 128-dimensional speaker embedding
```

Its processing is:

```text
CNN learns frequency characteristics
LSTM learns time-dependent speaker behavior
projection layer produces the embedding
L2 normalization gives a stable vector length
```

We then calculate cosine similarity between the saved local embedding and the new local embedding.

The trained checkpoint currently supplies a threshold around:

```text
0.62
```

The decision is:

```text
similarity >= threshold -> same speaker
similarity < threshold  -> different speaker
```

This model is used as a secondary signal because it represents our localized dataset and project research, but its current test performance is not strong enough to replace ECAPA.

## 9. How Enrollment Works In The Integrated System

The Flutter app sends enrollment samples to:

```text
POST /enroll/
```

The request contains:

```text
contact_id
source_quality
one or more audio_files
```

We use:

```text
source_quality=high
```

for clean manual enrollment, and:

```text
source_quality=low
```

for call-time enrollment.

The backend then performs these steps:

```text
1. Decode every sample.
2. Measure duration, RMS level and peak level.
3. Reject samples that are too short or contain no usable speech.
4. Normalize accepted audio.
5. Extract one ECAPA embedding per accepted sample.
6. Extract one CNN + LSTM embedding when the secondary model is available.
7. Compare ECAPA enrollment samples for consistency.
8. Reject inconsistent enrollment samples.
9. Average and normalize the accepted embeddings.
10. Save the final voiceprints.
```

The saved files are:

```text
voiceprints/CONTACT_ID.npy
voiceprints/CONTACT_ID.cnn_lstm.npy
```

The first file is the ECAPA voiceprint.

The second file is our CNN + LSTM speaker embedding voiceprint.

## 10. Why We Require Multiple Enrollment Samples

We do not want one accidental sound to become the permanent voiceprint.

The backend currently requires at least two usable samples. The mobile call-time flow collects several segments before submitting enrollment.

We then calculate consistency between ECAPA embeddings.

This helps us reject cases where the samples contain:

```text
two different speakers
mostly noise
the phone owner's voice instead of the remote speaker
unstable or mixed audio
```

The consistency requirement is currently lower for call audio because call channels are noisier than clean enrollment recordings.

## 11. How Verification Works In The Integrated System

The Flutter app sends a verification segment to:

```text
POST /verify/
```

The request contains:

```text
contact_id
audio_file
source_quality
audio_role
media_source
```

For call verification, we label the intended content as:

```text
audio_role=remote_speaker
```

The backend then follows this sequence:

```text
1. Check that the contact has an enrolled voiceprint.
2. Decode, normalize and inspect the audio.
3. Reject silent audio without producing a false identity decision.
4. Split the audio into segments.
5. Run CNN + LSTM v2 anti-spoofing on the segments.
6. Run ECAPA against the saved ECAPA voiceprint.
7. Run the CNN + LSTM speaker model against its saved voiceprint.
8. Combine the available evidence into the final response.
9. Store the event for dashboard and detection history use.
```

## 12. How The Final Backend Verdict Is Produced

The current final decision gives ECAPA the primary authority.

The configured values are:

```text
primary match threshold: 0.55
high verification threshold: 0.65
clear mismatch threshold: 0.20
noisy call confidence fallback: 0.40
secondary warning margin: 0.12
anti-spoofing internal threshold: 0.32
```

The final backend behavior is approximately:

```text
ECAPA match and similarity >= 0.65
-> verified_high

ECAPA match and similarity >= 0.55
-> verified

ECAPA mismatch but pretreated call audio has sufficient confidence
-> verified with a noisy-call warning

ECAPA similarity < 0.20
-> not_verified

other unresolved cases
-> uncertain
```

When ECAPA and the secondary model both match, the backend can explain that both models agree.

The backend calculates anti-spoofing evidence, but the current final-verdict function deliberately does not convert it into `spoof_detected` because we are still calibrating false positives on real calls.

## 13. What The Backend Returns To The Mobile App

The verification response includes:

```text
verdict
is_verified
is_spoof
spoof_probability
similarity_score
confidence
segments_analyzed
anti_spoofing result
primary ECAPA result
secondary CNN + LSTM result
audio_role
media_source
```

This separation is important.

It allows us to understand whether a result came from:

```text
speaker mismatch
anti-spoofing risk
missing secondary model
silent audio
poor call capture
```

instead of reducing every problem to one unexplained percentage.

## 14. How The Mobile Application Uses The Result

The Flutter service is:

```text
voiceguard/app/lib/core/services/verification_service.dart
```

It performs these responsibilities:

```text
send enrollment samples
check enrollment status
send verification segments
parse backend results
ignore stale results from previous calls
smooth several call results
update the in-call interface
support detection history
```

The mobile app keeps a rolling window of the latest three meaningful verification results.

This helps prevent one noisy segment from immediately changing the displayed identity result.

For the smoothed mobile verdict to remain verified, it currently expects:

```text
average similarity >= 0.45
average confidence >= 0.65
```

These are mobile presentation safeguards. They are separate from the backend model thresholds.

## 15. How We Keep The Correct Speaker In The Pipeline

The model can only verify the correct person if we send the correct person's audio.

For VoiceGuard, the required audio is:

```text
the remote speaker
```

It must not be:

```text
the phone owner's microphone voice
mixed speech from both people
silence
ringtone audio
old audio from a previous call
```

For VoIP, the application records the relayed remote audio stream for enrollment and verification.

For cellular calls, the application first attempts the configured shell/downlink capture path. When that is unavailable, normal Android restrictions mean speakerphone acoustic capture may still be required.

The application sends `audio_role` and `media_source` metadata so the backend and history can explain where the sample came from.

## 16. How Models Are Loaded When FastAPI Starts

The model objects are created as singleton services. This means we load each large model once and reuse it for requests.

The expected sequence is:

```text
FastAPI starts
-> verification service is requested
-> ECAPA model loads
-> CNN + LSTM v2 checkpoint loads
-> CNN + LSTM speaker checkpoint loads
-> models move to CUDA when available, otherwise CPU
-> later requests reuse the loaded models
```

The local models search for these paths:

```text
aiworks/models/cnn_lstm_v2/best_model.pt
aiworks/models/speaker_embedding/best_model.pt
```

The paths can also be supplied through:

```text
CNN_LSTM_V2_MODEL_PATH
SPEAKER_EMBEDDING_MODEL_PATH
```

If the secondary model is missing, ECAPA verification can still run. The response reports that the secondary signal is unavailable.

## 17. AASIST Naming In The Current Code

The backend contains:

```text
voiceguard/ai_backend/app/models/aasist.py
```

At present, this is a compatibility wrapper. It does not load a separate trained AASIST checkpoint.

It forwards anti-spoofing requests to:

```text
CNN + LSTM v2
```

Therefore, when we describe the running anti-spoofing model, the accurate statement is:

```text
CNN + LSTM v2 is active through the AASIST-compatible wrapper.
```

We should not claim that a separate AASIST model is currently producing the scores unless we later integrate and load actual AASIST weights.

## 18. Complete Integrated Flow

The full enrollment flow is:

```text
remote speaker talks
-> mobile captures remote-speaker segments
-> mobile submits several samples to /enroll/
-> backend validates quality and speech
-> ECAPA creates primary embeddings
-> CNN + LSTM creates secondary embeddings
-> backend checks consistency
-> backend averages embeddings
-> backend saves two voiceprints
```

The full verification flow is:

```text
remote speaker talks on a later call
-> mobile captures a remote-speaker segment
-> mobile submits it to /verify/
-> backend checks speech
-> CNN + LSTM v2 produces spoof risk
-> ECAPA compares primary voiceprints
-> CNN + LSTM compares secondary voiceprints
-> backend produces a verdict
-> mobile smooths recent results
-> user receives in-call feedback
-> event appears in detection history and dashboard data
```

## 19. What Is Strong And What Still Needs Improvement

Our strongest current part is:

```text
ECAPA speaker verification on the prepared test pairs
```

Our important project-specific additions are:

```text
localized CNN + LSTM anti-spoofing
localized CNN + LSTM speaker embeddings
dual voiceprint enrollment
remote-speaker metadata
call-time result smoothing
```

The areas that still need deeper evaluation are:

```text
anti-spoof threshold calibration on real phone calls
speaker thresholds for each capture method
more speakers and more devices
different accents and environments
cellular codec and VoIP codec variation
echo and mixed-speaker rejection
replay attacks and unseen clone generators
```

## 20. Our Correct Current Description

The most accurate way for us to describe the integrated VoiceGuard AI system is:

```text
We use ECAPA-TDNN as the primary speaker-verification model.

We use our CNN + LSTM speaker embedding model as a secondary localized
speaker-verification signal.

We use our CNN + LSTM v2 model to calculate cloned-voice risk.

The cloned-voice score is currently recorded as risk telemetry while we
calibrate it against real mobile call audio, so it does not yet override
the final identity verdict.
```

This description matches both our model-training results and the current implementation.

