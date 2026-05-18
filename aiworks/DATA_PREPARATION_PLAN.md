# VoiceGuard Dataset Preparation Plan

This document explains the first practical step we are taking together before training the CNN and LSTM models.

We are not starting with training immediately. We are first preparing the dataset properly so that the model learns from clean, trustworthy audio instead of broken files, silence, duplicates, or mislabeled examples.

## Why We Start With A Manifest

The manifest is our map of the dataset.

Before we train anything, we need to know:

```text
what files exist
where each file is located
whether it is real or cloned
which dataset it came from
which speaker/session it belongs to
whether the file can be read
how long the audio is
what sample rate it uses
whether it is mono or stereo
whether it is usable for training
why a file was rejected
```

This prevents us from guessing. It also makes the rest of the AI work repeatable.

## What The Script Does

We created:

```text
scripts\prepare_manifest.py
```

The script scans:

```text
datagroup1
datagroup2
```

It uses the folder names to understand the labels:

```text
really_voices  -> real
cloned_voices  -> cloned
```

Then it writes:

```text
manifests\raw_manifest.csv
manifests\clean_manifest.csv
reports\dataset_summary.md
```

## Raw Manifest

The raw manifest contains every audio file that was found.

This is important because we do not want to lose sight of files that are currently not usable. Some rejected files may be fixable later through conversion or repair.

## Clean Manifest

The clean manifest contains only files that passed the first basic checks.

For now, a file is considered clean only if:

```text
it has a known label
it is a WAV file
it can be read
it is not tiny or empty
it is at least 1 second long
it has valid audio metadata
```

This clean manifest is not the final training manifest yet. It is the first safe version.

## Why Some Files Are Rejected

Rejected files are not automatically useless. They are simply not ready for training right now.

Examples:

```text
MP3 and AMR files need conversion
broken WAV files need inspection
very small files are probably empty or corrupted
very short files may not contain enough speech
unknown labels cannot be trained safely
```

The goal is not to throw data away carelessly. The goal is to protect the training process from bad input.

## What We Do After This

After the manifest step, we move to audio normalization.

The next script should:

```text
read the raw manifest
convert usable audio formats to WAV
resample everything to 16 kHz
convert stereo to mono
save normalized audio into a prepared folder
update the manifest
```

Then we continue with:

```text
silence trimming
loudness normalization
duplicate detection
train/validation/test split
feature extraction
CNN baseline training
CNN + LSTM training
evaluation
backend integration
```

## Why This Matters For VoiceGuard

VoiceGuard will only become stronger if our training data is reliable.

If we train too early, the model may learn:

```text
file format differences
volume differences
speaker leakage
silence patterns
corrupted file artifacts
dataset noise
```

But if we prepare the data carefully, the model has a better chance of learning what we actually care about:

```text
the difference between real human voices and cloned/generated voices
```

That is why this manifest step is the correct first move.
