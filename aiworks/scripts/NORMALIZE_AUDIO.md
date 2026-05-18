# Normalize Audio Script

This document explains the second dataset preparation script we are using together for VoiceGuard AI training.

The script is:

```text
scripts\normalize_audio.py
```

## Why We Need This Script

Our datasets contain different audio formats and different recording settings. Some files are WAV, some are MP3, and some are AMR. Some WAV files use 16 kHz, others use 44.1 kHz or 48 kHz. Some are mono, others are stereo.

If we train directly on mixed formats, the model may learn format differences instead of learning the real difference between human voices and cloned voices.

So we normalize the audio first.

## What The Script Does

The script reads:

```text
manifests\raw_manifest.csv
```

Then for each labeled audio file, it tries to:

```text
load the audio
convert it to mono
resample it to 16 kHz
trim long silence
normalize peak volume
save a clean WAV copy
record the result in a new manifest
```

The clean audio is saved here:

```text
prepared_audio
```

The updated manifest is saved here:

```text
manifests\normalized_manifest.csv
```

The result report is saved here:

```text
reports\normalization_report.md
```

## Target Audio Format

Every successful file becomes:

```text
16 kHz
mono
WAV
16-bit PCM
```

This is the format we want before feature extraction.

## Why We Trim Silence

Some recordings may have empty audio at the beginning or end. We remove long silence so the model focuses more on speech.

We are not trying to destroy natural speech pauses. We are only removing useless empty sections that do not help training.

## Why We Normalize Volume

Some clips are loud and some are quiet. If we leave them as they are, the model may confuse volume differences with real/fake differences.

Volume normalization helps the model focus more on voice quality and clone artifacts.

## What Happens To Rejected Files

If a file cannot be loaded, is too short after trimming, is too small, or has an unknown label, the script does not use it for normalized audio.

It records the rejection reason in:

```text
manifests\normalized_manifest.csv
reports\normalization_report.md
```

That way we can understand what happened instead of silently losing files.

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\normalize_audio.py
```

For a quick small test:

```powershell
python scripts\normalize_audio.py --limit 50
```

## What Comes After This

After normalization, the next steps are:

```text
remove duplicate audio
check speech quality
create train/validation/test splits
extract log-mel spectrogram features
train the CNN baseline
train the CNN + LSTM model
evaluate both models
connect the stronger model to VoiceGuard backend
```

This script gets us closer to real model training, but it is still part of preparation. We train only after the dataset is clean, normalized, split, and converted into features.
