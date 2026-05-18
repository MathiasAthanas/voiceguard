# Dataset Manifest Summary

This report is the first preparation checkpoint for our VoiceGuard AI training work. We are not training yet. We are first making the dataset visible, measurable, and safer to use.

## What We Did

We scanned the audio files in:

```text
datagroup1
datagroup2
```

For each file, we recorded:

```text
path
dataset
speaker/session ID
label
file type
file size
duration
sample rate
channel count
readability
usable/rejected status
rejection reason
file hash
```

## Output Files

```text
manifests/raw_manifest.csv
manifests/clean_manifest.csv
reports/dataset_summary.md
```

The raw manifest keeps every audio file we found. The clean manifest keeps only files that passed this first basic scan.

## Overall Counts

- Total audio files scanned: 4949
- Files currently usable: 3998
- Files currently rejected: 951

## Counts By Label

- cloned: 2265
- real: 2684

## Clean Counts By Label

- cloned: 1332
- real: 2666

## Counts By Dataset And Label

- datagroup1 / cloned: 1232
- datagroup1 / real: 1652
- datagroup2 / cloned: 1033
- datagroup2 / real: 1032

## Clean Counts By Dataset And Label

- datagroup1 / cloned: 572
- datagroup1 / real: 1647
- datagroup2 / cloned: 760
- datagroup2 / real: 1019

## File Types

- .amr: 14
- .mp3: 455
- .wav: 4480

## Sample Rates In Clean WAV Files

- 16000: 2489
- 32000: 9
- 44100: 1484
- 48000: 16

## Channel Counts In Clean WAV Files

- 1: 3938
- 2: 60

## Duration Summary For Clean Files

- Minimum: 1.17s
- Median: 8.00s
- Mean: 7.72s
- Maximum: 15.08s

## Rejection Reasons

- duration_too_short: 7
- file_too_small: 74
- needs_audio_conversion: 469
- needs_conversion_before_metadata: 469
- unreadable_wav:Error: 475

## Duplicate Hashes

- Duplicate file hashes found: 496

## What This Means

This first scan tells us which files are already safe to use and which files need conversion or repair. Files such as MP3 and AMR are not bad, but they need conversion before they can enter the clean training set. Broken WAV files also need to be inspected or excluded.

The next preparation step is to create normalized audio:

```text
16 kHz
mono
WAV
16-bit PCM
```

After that, we can trim silence, normalize loudness, remove duplicates, split the dataset properly, and extract log-mel spectrogram features for CNN/LSTM training.
