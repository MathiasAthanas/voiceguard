# Extract Log-Mel Features Script

This document explains the feature extraction script we are using together for VoiceGuard AI model training.

The script is:

```text
scripts\extract_logmel_features.py
```

## Why We Need This Script

The CNN and LSTM models should not train directly from messy raw audio files.

After cleaning, normalizing, filtering, and splitting the audio, we convert each audio file into a feature that the model can learn from.

For our first serious training stage, that feature is:

```text
log-mel spectrogram
```

## What A Log-Mel Spectrogram Is

A log-mel spectrogram is a visual representation of sound.

It shows:

```text
how voice energy changes across frequencies
how those patterns move over time
```

This is useful because cloned voices often contain unnatural frequency and time-pattern artifacts.

## Why This Helps CNN And LSTM Models

The CNN can look at the spectrogram like an image and learn local voice patterns.

The LSTM can later study how those patterns change over time.

So this feature extraction step prepares the same input foundation for:

```text
CNN baseline model
CNN + LSTM model
```

## What The Script Reads

```text
splits\train.csv
splits\validation.csv
splits\test.csv
```

## What The Script Writes

Feature files:

```text
features\logmel\train
features\logmel\validation
features\logmel\test
```

Feature manifests:

```text
features\manifests\train_features.csv
features\manifests\validation_features.csv
features\manifests\test_features.csv
```

Result report:

```text
reports\feature_extraction_report.md
```

## Feature Settings

The first feature extraction version uses:

```text
sample rate: 16 kHz
clip length: 4 seconds
mel bands: 64
FFT size: 400
hop length: 160
feature type: normalized log-mel spectrogram
saved type: float16
```

If a clip is longer than 4 seconds, we take the center 4 seconds.

If a clip is shorter than 4 seconds, we pad it carefully.

This gives the model a consistent input size.

## How To Run It

From PowerShell:

```powershell
cd C:\Users\MICROSPACE\Desktop\matt\aiclone\aiworks
python scripts\extract_logmel_features.py
```

For a quick test:

```powershell
python scripts\extract_logmel_features.py --limit 20
```

## What Comes After This

After this script runs successfully, we can begin model training.

The next scripts should be:

```text
train_cnn_baseline.py
train_cnn_lstm.py
evaluate_model.py
```

This is where the AI work moves from data preparation into actual learning.
