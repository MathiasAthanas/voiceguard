# Filter Quality And Duplicates Script

This document explains the third dataset preparation script we are using together for VoiceGuard AI training.

The script is:

```text
scripts\filter_quality_and_duplicates.py
```

## Why We Need This Script

After normalization, we have audio in one consistent format. But consistency alone is not enough.

We still need to remove files that could damage training, such as:

```text
duplicate audio
missing prepared files
very quiet audio
near-silent audio
low speech activity
files that failed normalization
```

This script creates a safer list of files for train/validation/test splitting.

## What The Script Reads

```text
manifests\normalized_manifest.csv
```

## What The Script Checks

For every normalized row, it checks:

```text
whether the normalized file exists
whether the row was normalized successfully
whether the audio hash is duplicated
duration
RMS loudness
peak level
speech activity ratio
```

## What The Script Writes

```text
manifests\filtered_manifest.csv
reports\filtering_report.md
```

## Important Point

This script does not delete any audio files.

It only marks which files are accepted for splitting and which files are rejected. That way we can always go back and inspect rejected files later.

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\filter_quality_and_duplicates.py
```

## What Comes After This

After filtering, we split accepted files into:

```text
train
validation
test
```

That split becomes the foundation for feature extraction and CNN/LSTM training.
