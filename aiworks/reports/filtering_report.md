# Filtering Report

This report is the third preparation checkpoint for our VoiceGuard AI training work. In this step, we are protecting the model from duplicated audio and weak speech samples.

## What We Did Together

We read:

```text
manifests/normalized_manifest.csv
```

Then we checked each normalized file for:

```text
duplicate audio hashes
missing normalized files
duration
loudness
peak level
speech activity
normalization status
```

## Output File

```text
manifests/filtered_manifest.csv
```

This manifest is the first one we should use for train/validation/test splitting.

## Overall Result

- Rows checked: 4949
- Accepted for splitting: 3769
- Rejected after filtering: 1180

## Accepted Files By Label

- cloned: 1634
- real: 2135

## Accepted Files By Dataset And Label

- datagroup1 / cloned: 1225
- datagroup1 / real: 1633
- datagroup2 / cloned: 409
- datagroup2 / real: 502

## Rejection Reasons

- NoBackendError: 40
- duplicate_normalized_audio: 1044
- duration_too_short_after_trim: 8
- file_too_small: 74
- low_speech_activity: 1
- near_silent_audio: 13
- normalized_file_missing: 135

## What This Means

This step does not delete the original data. It simply tells the training pipeline which normalized files are safer to use.

The next step is to split accepted files into:

```text
train
validation
test
```

We should split by speaker/session as much as possible so our evaluation is more honest and does not simply reward memorization.
