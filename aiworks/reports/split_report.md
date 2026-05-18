# Dataset Split Report

This report is the fourth preparation checkpoint for our VoiceGuard AI training work. In this step, we divided the filtered dataset into training, validation, and test sets.

## What We Did Together

We read:

```text
manifests/filtered_manifest.csv
```

Then we kept only accepted rows and split them into:

```text
train
validation
test
```

The script groups files by:

```text
dataset + speaker/session ID
```

This helps reduce leakage, because clips from the same speaker/session should not be scattered randomly across every split.

## Output Files

```text
splits/train.csv
splits/validation.csv
splits/test.csv
```

## Overall Split Result

- Total accepted files split: 3769

### Train

- Files: 2647
- Speaker/session groups: 12

Label counts:

- cloned: 1137
- real: 1510


### Validation

- Files: 548
- Speaker/session groups: 3

Label counts:

- cloned: 298
- real: 250


### Test

- Files: 574
- Speaker/session groups: 4

Label counts:

- cloned: 199
- real: 375


## What This Means

The training split is what the model learns from.

The validation split is what we use while tuning the model.

The test split is what we keep for honest final evaluation.

The next step is feature extraction. We will convert these split files into log-mel spectrogram features so the CNN and CNN + LSTM models can learn real-vs-cloned voice patterns.
