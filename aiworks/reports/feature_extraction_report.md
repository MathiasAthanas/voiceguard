# Feature Extraction Report

This report is the fifth preparation checkpoint for our VoiceGuard AI training work. In this step, we turned prepared audio into model-ready features.

## What We Did Together

We read the split files:

```text
splits/train.csv
splits/validation.csv
splits/test.csv
```

Then we converted each audio file into a fixed-size log-mel spectrogram.

## Output Files

```text
features/logmel/train
features/logmel/validation
features/logmel/test
features/manifests/train_features.csv
features/manifests/validation_features.csv
features/manifests/test_features.csv
```

## Feature Settings

```text
sample rate: 16000
clip length: 4.0 seconds
mel bands: 64
FFT size: 400
hop length: 160
frequency range: 20 Hz to 7600 Hz
feature dtype: float16
```

Each feature is normalized so the model focuses more on voice patterns than raw volume.

## Overall Result

- Rows attempted: 3769
- Features extracted: 3769
- Rows rejected: 0

## Extracted Features By Split

- test: 574
- train: 2647
- validation: 548

## Extracted Features By Split And Label

- test / cloned: 199
- test / real: 375
- train / cloned: 1137
- train / real: 1510
- validation / cloned: 298
- validation / real: 250

## Feature Shapes

- 64x401: 3769

## Rejection Reasons

No rows found.

## What This Means

The dataset is now ready for the first model-training script.

The CNN can learn from these log-mel spectrograms as image-like voice patterns. The CNN + LSTM model can use the same features and learn how those patterns behave over time.

The next step is to train a CNN baseline model, evaluate it, and then compare it with a CNN + LSTM model.
