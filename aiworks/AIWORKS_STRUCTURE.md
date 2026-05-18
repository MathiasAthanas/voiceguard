# AIWorks Folder Structure

This document explains how the `aiworks` folder is organized and how each part helps us move from raw voice data to trained VoiceGuard AI models.

The goal is to make this work understandable and repeatable. When we add more scripts, datasets, reports, or trained models, we should keep using this structure so we always know where things belong.

## Main Folder

```text
aiworks
```

This is our working area for AI model training. It is separate from the mobile app and backend so we can prepare data, run experiments, and train models without mixing training files into the production application.

## Raw Datasets

```text
datagroup1
datagroup2
```

These are the original datasets we are starting from.

They contain:

```text
really_voices  -> real/original voices
cloned_voices  -> cloned/fake/generated voices
```

We should treat these folders as source data. We should avoid editing them directly. Instead, scripts should create prepared copies in separate folders.

## Scripts

```text
scripts
```

This folder contains the Python scripts that prepare the dataset and later train/evaluate models.

Current scripts:

```text
scripts\prepare_manifest.py
scripts\normalize_audio.py
```

Each script should have its own markdown explanation beside it.

Current script docs:

```text
scripts\NORMALIZE_AUDIO.md
```

The manifest script is also explained through:

```text
DATA_PREPARATION_PLAN.md
reports\dataset_summary.md
```

## Manifests

```text
manifests
```

Manifests are CSV files that describe the dataset.

Current manifests:

```text
manifests\raw_manifest.csv
manifests\clean_manifest.csv
manifests\normalized_manifest.csv
```

What they mean:

```text
raw_manifest.csv        -> every audio file found in the raw datasets
clean_manifest.csv      -> files that passed the first basic scan
normalized_manifest.csv -> result of the audio normalization step
```

Manifests are important because they make the training process traceable. We can always see which files were used, rejected, converted, or prepared.

## Prepared Audio

```text
prepared_audio
```

This folder stores normalized training audio.

The target format is:

```text
16 kHz
mono
WAV
16-bit PCM
```

This is the audio we will use for later stages such as duplicate removal, dataset splitting, and feature extraction.

## Reports

```text
reports
```

Reports explain what happened after each preparation or training step.

Current reports:

```text
reports\dataset_summary.md
reports\normalization_report.md
```

Reports are important because they let us understand the results without opening CSV files manually.

Every major script should produce a report.

## Training Guide

```text
TRAINING_GUIDE.md
```

This is the high-level explanation of what we are doing together. It explains why we are training CNN and LSTM models, how data preparation works, and how the new models should eventually connect to VoiceGuard.

## Data Preparation Plan

```text
DATA_PREPARATION_PLAN.md
```

This explains the first practical stage: creating a dataset manifest and making the dataset measurable before training.

## Future Folders

As we continue, we should add:

```text
features
splits
models
experiments
evaluation
```

Recommended meaning:

```text
features    -> extracted log-mel spectrograms or feature tensors
splits      -> train.csv, validation.csv, test.csv
models      -> saved trained CNN/LSTM model files
experiments -> training configs and run histories
evaluation  -> metrics, confusion matrices, comparison reports
```

## How The Whole Flow Works

The full path should be:

```text
raw datasets
-> raw manifest
-> normalized audio
-> duplicate and quality filtering
-> train/validation/test split
-> feature extraction
-> CNN training
-> CNN + LSTM training
-> evaluation
-> backend integration
```

This structure keeps us disciplined. We do not jump into training before the data is ready, and we do not lose track of how a final model was created.
