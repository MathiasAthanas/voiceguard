"""
Extract log-mel spectrogram features for VoiceGuard CNN/LSTM training.

This script reads:
  splits/train.csv
  splits/validation.csv
  splits/test.csv

It writes:
  features/logmel/<split>/*.npy
  features/manifests/<split>_features.csv
  reports/feature_extraction_report.md

Each feature is a fixed-size normalized log-mel spectrogram.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
from dataclasses import asdict, dataclass
from pathlib import Path

import librosa
import numpy as np


SAMPLE_RATE = 16_000
CLIP_SECONDS = 4.0
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 64
FMIN = 20
FMAX = 7_600
EPS = 1e-6


@dataclass
class FeatureRow:
    feature_path: str
    normalized_path: str
    split: str
    dataset: str
    speaker_id: str
    label: str
    label_id: int
    duration_seconds: str
    feature_shape: str
    n_mels: int
    frames: int
    clip_seconds: float
    status: str
    reject_reason: str


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[FeatureRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(asdict(rows[0]).keys()) if rows else list(FeatureRow.__annotations__.keys())
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def fixed_length_audio(audio: np.ndarray) -> np.ndarray:
    target_len = int(SAMPLE_RATE * CLIP_SECONDS)
    if audio.size == target_len:
        return audio
    if audio.size < target_len:
        pad = target_len - audio.size
        left = pad // 2
        right = pad - left
        return np.pad(audio, (left, right), mode="constant")

    start = max((audio.size - target_len) // 2, 0)
    return audio[start : start + target_len]


def extract_feature(path: Path) -> np.ndarray:
    audio, _ = librosa.load(str(path), sr=SAMPLE_RATE, mono=True)
    if audio.size == 0:
        raise ValueError("empty_audio")

    audio = fixed_length_audio(audio.astype(np.float32))
    mel = librosa.feature.melspectrogram(
        y=audio,
        sr=SAMPLE_RATE,
        n_fft=N_FFT,
        hop_length=HOP_LENGTH,
        n_mels=N_MELS,
        fmin=FMIN,
        fmax=FMAX,
        power=2.0,
    )
    logmel = librosa.power_to_db(mel, ref=np.max)
    logmel = (logmel - float(np.mean(logmel))) / (float(np.std(logmel)) + EPS)
    return logmel.astype(np.float16)


def label_id(label: str) -> int:
    return 1 if label == "cloned" else 0


def feature_path(root: Path, split: str, row: dict[str, str]) -> Path:
    source = Path(row["normalized_path"])
    digest = hashlib.sha1(str(source).encode("utf-8")).hexdigest()[:10]
    name = f"{row['dataset']}_{row['speaker_id']}_{row['label']}_{source.stem}_{digest}.npy"
    return root / "features" / "logmel" / split / name


def build_feature_row(root: Path, split: str, row: dict[str, str]) -> FeatureRow:
    source = Path(row["normalized_path"])
    target = feature_path(root, split, row)
    try:
        feature = extract_feature(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        np.save(target, feature)
        return FeatureRow(
            feature_path=str(target),
            normalized_path=str(source),
            split=split,
            dataset=row["dataset"],
            speaker_id=row["speaker_id"],
            label=row["label"],
            label_id=label_id(row["label"]),
            duration_seconds=row.get("duration_seconds", ""),
            feature_shape="x".join(str(dim) for dim in feature.shape),
            n_mels=feature.shape[0],
            frames=feature.shape[1],
            clip_seconds=CLIP_SECONDS,
            status="extracted",
            reject_reason="",
        )
    except Exception as exc:
        return FeatureRow(
            feature_path=str(target),
            normalized_path=str(source),
            split=split,
            dataset=row.get("dataset", ""),
            speaker_id=row.get("speaker_id", ""),
            label=row.get("label", ""),
            label_id=label_id(row.get("label", "")),
            duration_seconds=row.get("duration_seconds", ""),
            feature_shape="",
            n_mels=N_MELS,
            frames=0,
            clip_seconds=CLIP_SECONDS,
            status="rejected",
            reject_reason=f"{type(exc).__name__}:{str(exc)[:200]}",
        )


def count_by(rows: list[FeatureRow], *fields: str) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        key = tuple(str(getattr(row, field)) for field in fields)
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def format_counts(counts: dict[tuple[str, ...], int]) -> str:
    if not counts:
        return "No rows found.\n"
    return "\n".join(f"- {' / '.join(key)}: {value}" for key, value in counts.items()) + "\n"


def write_report(path: Path, rows: list[FeatureRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    extracted = [row for row in rows if row.status == "extracted"]
    rejected = [row for row in rows if row.status != "extracted"]

    text = f"""# Feature Extraction Report

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
sample rate: {SAMPLE_RATE}
clip length: {CLIP_SECONDS} seconds
mel bands: {N_MELS}
FFT size: {N_FFT}
hop length: {HOP_LENGTH}
frequency range: {FMIN} Hz to {FMAX} Hz
feature dtype: float16
```

Each feature is normalized so the model focuses more on voice patterns than raw volume.

## Overall Result

- Rows attempted: {len(rows)}
- Features extracted: {len(extracted)}
- Rows rejected: {len(rejected)}

## Extracted Features By Split

{format_counts(count_by(extracted, "split"))}
## Extracted Features By Split And Label

{format_counts(count_by(extracted, "split", "label"))}
## Feature Shapes

{format_counts(count_by(extracted, "feature_shape"))}
## Rejection Reasons

{format_counts(count_by(rejected, "reject_reason"))}
## What This Means

The dataset is now ready for the first model-training script.

The CNN can learn from these log-mel spectrograms as image-like voice patterns. The CNN + LSTM model can use the same features and learn how those patterns behave over time.

The next step is to train a CNN baseline model, evaluate it, and then compare it with a CNN + LSTM model.
"""
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract VoiceGuard log-mel features.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to the aiworks folder.",
    )
    parser.add_argument("--limit", type=int, default=None, help="Optional per-split limit.")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    split_dir = root / "splits"
    manifest_dir = root / "features" / "manifests"
    report_path = root / "reports" / "feature_extraction_report.md"

    all_rows: list[FeatureRow] = []
    for split in ("train", "validation", "test"):
        split_rows = read_csv(split_dir / f"{split}.csv")
        if args.limit is not None:
            split_rows = split_rows[: args.limit]
        feature_rows = []
        for index, row in enumerate(split_rows, start=1):
            feature_rows.append(build_feature_row(root, split, row))
            if index % 250 == 0:
                print(f"{split}: processed {index}/{len(split_rows)}")
        write_csv(manifest_dir / f"{split}_features.csv", feature_rows)
        all_rows.extend(feature_rows)

    write_report(report_path, all_rows)
    extracted_count = sum(1 for row in all_rows if row.status == "extracted")
    print(f"Rows attempted: {len(all_rows)}")
    print(f"Features extracted: {extracted_count}")
    print(f"Rows rejected: {len(all_rows) - extracted_count}")
    print(f"Wrote manifests under: {manifest_dir}")
    print(f"Wrote report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
