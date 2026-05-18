# Audio Normalization Report

This report is the second preparation checkpoint for our VoiceGuard AI training work. In this step, we started turning the raw dataset into consistent training audio.

## What We Did Together

We read:

```text
manifests/raw_manifest.csv
```

Then we attempted to load each labeled audio file, trim long silence, normalize the peak level, and save a clean copy as:

```text
16 kHz
mono
WAV
16-bit PCM
```

The normalized audio is stored in:

```text
prepared_audio
```

The updated manifest is:

```text
manifests/normalized_manifest.csv
```

## Overall Result

- Files attempted: 4949
- Files normalized: 4814
- Files rejected during normalization: 135

## Normalized Files By Label

- cloned: 2161
- real: 2653

## Normalized Files By Dataset And Label

- datagroup1 / cloned: 1227
- datagroup1 / real: 1634
- datagroup2 / cloned: 934
- datagroup2 / real: 1019

## Source File Types That Were Normalized

- .mp3: 455
- .wav: 4359

## Rejections By Reason

- NoBackendError: 40
- duration_too_short_after_trim: 8
- file_too_small: 74
- near_silent_audio: 13

## Normalized Duration Summary

- Minimum: 1.09s
- Median: 7.86s
- Mean: 7.39s
- Maximum: 15.05s

## What This Means

This step gives us one consistent audio format for model preparation. That is important because the CNN and LSTM should learn voice and clone patterns, not file format differences.

This is still not the final training set. The next stage should remove duplicates, check speech quality more deeply, split the dataset into train/validation/test, and then extract log-mel spectrogram features.
