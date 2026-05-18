"""
Generate a readable overview of the aiworks folder.

This script is our quick map of the AI training workspace. It explains what
exists, what each folder is for, and how the pieces connect.

Output:
  reports/aiworks_overview.md
"""

from __future__ import annotations

import csv
from pathlib import Path


def count_files(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for item in path.rglob("*") if item.is_file())


def count_dirs(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for item in path.rglob("*") if item.is_dir())


def csv_rows(path: Path) -> int:
    if not path.exists():
        return 0
    with path.open("r", newline="", encoding="utf-8") as handle:
        return max(sum(1 for _ in csv.reader(handle)) - 1, 0)


def write_overview(root: Path) -> Path:
    reports = root / "reports"
    reports.mkdir(parents=True, exist_ok=True)

    prepared_audio = root / "prepared_audio"
    manifests = root / "manifests"
    scripts = root / "scripts"
    splits = root / "splits"
    features = root / "features"

    text = f"""# AIWorks Current Overview

This report shows how our `aiworks` folder currently works. It is meant to help us stay organized as we move from raw voice datasets to CNN and LSTM model training.

## Main Idea

We are using `aiworks` as the training workspace for VoiceGuard.

This is where we:

```text
inspect the datasets
prepare audio
create manifests
write reports
extract features
train models
evaluate results
prepare backend integration
```

## Current Folder Structure

```text
aiworks
+-- datagroup1
+-- datagroup2
+-- manifests
+-- prepared_audio
+-- reports
+-- scripts
+-- splits
+-- features
+-- AIWORKS_STRUCTURE.md
+-- DATA_PREPARATION_PLAN.md
+-- TRAINING_GUIDE.md
```

## Raw Datasets

```text
datagroup1
datagroup2
```

These are our source datasets. They contain the real and cloned voice folders. We should keep these as the original reference and write prepared outputs somewhere else.

Raw dataset file count:

```text
datagroup1 files: {count_files(root / "datagroup1")}
datagroup2 files: {count_files(root / "datagroup2")}
```

## Scripts

```text
scripts
```

This folder contains the tools we use to prepare the data.

Current script files:

```text
{format_names(scripts.glob("*.py"))}
```

Current script documentation:

```text
{format_names(scripts.glob("*.md"))}
```

Each major script should have its own markdown file so we can explain what it does, why it exists, and what output it creates.

## Manifests

```text
manifests
```

These CSV files track the dataset at each stage.

Current manifest row counts:

```text
raw_manifest.csv:        {csv_rows(manifests / "raw_manifest.csv")}
clean_manifest.csv:      {csv_rows(manifests / "clean_manifest.csv")}
normalized_manifest.csv: {csv_rows(manifests / "normalized_manifest.csv")}
filtered_manifest.csv:   {csv_rows(manifests / "filtered_manifest.csv")}
```

The manifest files are important because they make our training process traceable. We can always explain what files were used and why some files were rejected.

## Prepared Audio

```text
prepared_audio
```

This folder contains normalized audio for future training steps.

Prepared audio status:

```text
folders: {count_dirs(prepared_audio)}
files:   {count_files(prepared_audio)}
```

The target format is:

```text
16 kHz
mono
WAV
16-bit PCM
```

## Splits

```text
splits
```

## Features

```text
features
```

This folder contains model-ready feature files. Right now we are using log-mel spectrogram features.

Feature file counts:

```text
features/logmel/train:      {count_files(features / "logmel" / "train")}
features/logmel/validation: {count_files(features / "logmel" / "validation")}
features/logmel/test:       {count_files(features / "logmel" / "test")}
```

Feature manifest row counts:

```text
train_features.csv:      {csv_rows(features / "manifests" / "train_features.csv")}
validation_features.csv: {csv_rows(features / "manifests" / "validation_features.csv")}
test_features.csv:       {csv_rows(features / "manifests" / "test_features.csv")}
```

These files divide the accepted prepared audio into model-development sets.

Current split row counts:

```text
train.csv:      {csv_rows(splits / "train.csv")}
validation.csv: {csv_rows(splits / "validation.csv")}
test.csv:       {csv_rows(splits / "test.csv")}
```

## Reports

```text
reports
```

Reports explain the result of each stage.

Current reports:

```text
{format_names(reports.glob("*.md"))}
```

Reports help us understand progress without manually opening every CSV file.

## How Everything Connects

The current flow is:

```text
datagroup1 + datagroup2
-> scripts\\prepare_manifest.py
-> manifests\\raw_manifest.csv
-> manifests\\clean_manifest.csv
-> reports\\dataset_summary.md
-> scripts\\normalize_audio.py
-> prepared_audio
-> manifests\\normalized_manifest.csv
-> reports\\normalization_report.md
-> scripts\\filter_quality_and_duplicates.py
-> manifests\\filtered_manifest.csv
-> reports\\filtering_report.md
-> scripts\\create_dataset_splits.py
-> splits\\train.csv
-> splits\\validation.csv
-> splits\\test.csv
-> reports\\split_report.md
-> scripts\\extract_logmel_features.py
-> features\\logmel\\train
-> features\\logmel\\validation
-> features\\logmel\\test
-> features\\manifests\\train_features.csv
-> features\\manifests\\validation_features.csv
-> features\\manifests\\test_features.csv
-> reports\\feature_extraction_report.md
```

The next flow should be:

```text
features\\manifests\\train_features.csv
features\\manifests\\validation_features.csv
features\\manifests\\test_features.csv
-> CNN training
-> CNN + LSTM training
-> evaluation
-> backend integration
```

## Why This Structure Matters

We are building a serious AI pipeline, not just running one experiment.

This structure helps us:

```text
avoid training on broken data
explain every result
repeat the process later
compare models fairly
know exactly what entered training
prepare the model for VoiceGuard backend integration
```

That discipline is what gives the CNN and LSTM work a better chance of improving VoiceGuard in real use.
"""

    output = reports / "aiworks_overview.md"
    output.write_text(text, encoding="utf-8")
    return output


def format_names(paths) -> str:
    names = sorted(path.name for path in paths)
    if not names:
        return "none"
    return "\n".join(names)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    output = write_overview(root)
    print(f"Wrote: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
