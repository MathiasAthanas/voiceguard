# Prepare Manifest Script

This document explains the first script we created together for the VoiceGuard AI training work.

The script is:

```text
scripts\prepare_manifest.py
```

## Why We Need This Script

Before we train CNN or LSTM models, we need to understand the dataset clearly.

The raw folders contain real voices and cloned voices, but training code should not depend on guesswork. We need a structured file that tells us what each audio file is, where it came from, and whether it is currently safe to use.

That structured file is called a manifest.

## What The Script Scans

The script scans:

```text
datagroup1
datagroup2
```

It understands labels from folder names:

```text
really_voices  -> real
cloned_voices  -> cloned
```

## What The Script Records

For each audio file, it records:

```text
path
dataset
speaker/session ID
label
file extension
file size
duration
sample rate
channel count
whether it is readable
whether it is usable
why it was rejected
file hash
```

This gives us a clear view of the dataset before we modify or train anything.

## Output Files

The script creates:

```text
manifests\raw_manifest.csv
manifests\clean_manifest.csv
reports\dataset_summary.md
```

## Raw Manifest

The raw manifest keeps every audio file we found.

This is useful because even rejected files remain visible. Some files are rejected only because they need conversion, not because they are useless.

## Clean Manifest

The clean manifest keeps files that passed the first basic checks.

At this first stage, a clean file means:

```text
known label
readable WAV
not tiny
not shorter than 1 second
valid sample rate
valid channel count
```

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\prepare_manifest.py
```

## What Comes After This

After creating the manifest, we normalize the audio.

That means converting training audio into:

```text
16 kHz
mono
WAV
16-bit PCM
```

The manifest step is how we make the dataset measurable. The normalization step is how we make the audio consistent.
