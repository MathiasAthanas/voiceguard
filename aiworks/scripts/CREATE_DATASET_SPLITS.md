# Create Dataset Splits Script

This document explains the script we use to create train, validation, and test splits for VoiceGuard AI model training.

The script is:

```text
scripts\create_dataset_splits.py
```

## Why We Need This Script

After we normalize and filter the audio, we need to divide the accepted files into separate groups.

The model should not train and test on the same kind of data in a way that makes the results look better than they really are.

So we create:

```text
train
validation
test
```

## What Each Split Means

The training set is what the model learns from.

The validation set is what we use while tuning the model.

The test set is kept for final evaluation so we can judge the model more honestly.

## What The Script Reads

```text
manifests\filtered_manifest.csv
```

It only uses rows that were accepted by the filtering step.

## How The Split Works

The script groups files by:

```text
dataset + speaker/session ID
```

This is important because we do not want the same speaker/session scattered randomly across train, validation, and test.

Grouped splitting gives us a more realistic evaluation than simple random file splitting.

## What The Script Writes

```text
splits\train.csv
splits\validation.csv
splits\test.csv
reports\split_report.md
```

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\create_dataset_splits.py
```

## What Comes After This

After splitting, we extract features.

The next major output should be:

```text
log-mel spectrogram features
```

Those features will be used to train:

```text
CNN baseline model
CNN + LSTM temporal model
```

This is the point where the dataset becomes ready for actual model input preparation.
