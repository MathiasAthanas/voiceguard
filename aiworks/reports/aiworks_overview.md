# AIWorks Current Overview

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
datagroup1 files: 2884
datagroup2 files: 2065
```

## Scripts

```text
scripts
```

This folder contains the tools we use to prepare the data.

Current script files:

```text
create_dataset_splits.py
extract_logmel_features.py
filter_quality_and_duplicates.py
normalize_audio.py
prepare_manifest.py
show_aiworks_overview.py
```

Current script documentation:

```text
CREATE_DATASET_SPLITS.md
EXTRACT_LOGMEL_FEATURES.md
FILTER_QUALITY_AND_DUPLICATES.md
NORMALIZE_AUDIO.md
PREPARE_MANIFEST.md
SHOW_AIWORKS_OVERVIEW.md
```

Each major script should have its own markdown file so we can explain what it does, why it exists, and what output it creates.

## Manifests

```text
manifests
```

These CSV files track the dataset at each stage.

Current manifest row counts:

```text
raw_manifest.csv:        4949
clean_manifest.csv:      3998
normalized_manifest.csv: 4949
filtered_manifest.csv:   4949
```

The manifest files are important because they make our training process traceable. We can always explain what files were used and why some files were rejected.

## Prepared Audio

```text
prepared_audio
```

This folder contains normalized audio for future training steps.

Prepared audio status:

```text
folders: 61
files:   4814
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
features/logmel/train:      2647
features/logmel/validation: 548
features/logmel/test:       574
```

Feature manifest row counts:

```text
train_features.csv:      2647
validation_features.csv: 548
test_features.csv:       574
```

These files divide the accepted prepared audio into model-development sets.

Current split row counts:

```text
train.csv:      2647
validation.csv: 548
test.csv:       574
```

## Reports

```text
reports
```

Reports explain the result of each stage.

Current reports:

```text
aiworks_overview.md
dataset_summary.md
feature_extraction_report.md
filtering_report.md
normalization_report.md
split_report.md
```

Reports help us understand progress without manually opening every CSV file.

## How Everything Connects

The current flow is:

```text
datagroup1 + datagroup2
-> scripts\prepare_manifest.py
-> manifests\raw_manifest.csv
-> manifests\clean_manifest.csv
-> reports\dataset_summary.md
-> scripts\normalize_audio.py
-> prepared_audio
-> manifests\normalized_manifest.csv
-> reports\normalization_report.md
-> scripts\filter_quality_and_duplicates.py
-> manifests\filtered_manifest.csv
-> reports\filtering_report.md
-> scripts\create_dataset_splits.py
-> splits\train.csv
-> splits\validation.csv
-> splits\test.csv
-> reports\split_report.md
-> scripts\extract_logmel_features.py
-> features\logmel\train
-> features\logmel\validation
-> features\logmel\test
-> features\manifests\train_features.csv
-> features\manifests\validation_features.csv
-> features\manifests\test_features.csv
-> reports\feature_extraction_report.md
```

The next flow should be:

```text
features\manifests\train_features.csv
features\manifests\validation_features.csv
features\manifests\test_features.csv
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
