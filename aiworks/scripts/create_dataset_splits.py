"""
Create train/validation/test splits for VoiceGuard model training.

This script reads manifests/filtered_manifest.csv and writes:

  splits/train.csv
  splits/validation.csv
  splits/test.csv
  reports/split_report.md

It prefers speaker/session grouped splitting so clips from the same dataset
speaker group stay together.
"""

from __future__ import annotations

import argparse
import csv
import random
from collections import defaultdict
from pathlib import Path


TRAIN_RATIO = 0.70
VALIDATION_RATIO = 0.15
TEST_RATIO = 0.15
RANDOM_SEED = 42


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if rows:
        fieldnames = list(rows[0].keys())
    else:
        fieldnames = [
            "normalized_path",
            "dataset",
            "speaker_id",
            "label",
            "duration_seconds",
        ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def accepted_rows(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    return [row for row in rows if row.get("accepted") == "True"]


def group_rows(rows: list[dict[str, str]]) -> dict[tuple[str, str], list[dict[str, str]]]:
    groups: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        groups[(row["dataset"], row["speaker_id"])].append(row)
    return dict(groups)


def label_counts(rows: list[dict[str, str]]) -> dict[str, int]:
    counts = {"real": 0, "cloned": 0}
    for row in rows:
        label = row.get("label", "")
        counts[label] = counts.get(label, 0) + 1
    return counts


def split_score(current: dict[str, list[dict[str, str]]], split: str, group: list[dict[str, str]], targets: dict[str, int]) -> float:
    target = max(targets[split], 1)
    projected = len(current[split]) + len(group)
    fill_ratio = projected / target
    overflow_penalty = max(projected - target, 0) / target
    return fill_ratio + (overflow_penalty * 3.0)


def create_splits(rows: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    groups = list(group_rows(rows).items())
    rng = random.Random(RANDOM_SEED)
    rng.shuffle(groups)

    total = len(rows)
    targets = {
        "train": int(total * TRAIN_RATIO),
        "validation": int(total * VALIDATION_RATIO),
        "test": total - int(total * TRAIN_RATIO) - int(total * VALIDATION_RATIO),
    }

    splits = {"train": [], "validation": [], "test": []}
    groups.sort(key=lambda item: len(item[1]), reverse=True)

    for _, group in groups:
        under_target = [
            split for split in splits.keys() if len(splits[split]) < targets[split]
        ]
        candidates = under_target or list(splits.keys())
        best_split = min(
            candidates,
            key=lambda split: split_score(splits, split, group, targets),
        )
        splits[best_split].extend(group)

    for split_name, split_rows in splits.items():
        for row in split_rows:
            row["split"] = split_name

    return splits


def format_counts(counts: dict[str, int]) -> str:
    return "\n".join(f"- {key}: {value}" for key, value in sorted(counts.items())) + "\n"


def split_section(name: str, rows: list[dict[str, str]]) -> str:
    group_count = len({(row["dataset"], row["speaker_id"]) for row in rows})
    return f"""### {name}

- Files: {len(rows)}
- Speaker/session groups: {group_count}

Label counts:

{format_counts(label_counts(rows))}
"""


def write_report(path: Path, splits: dict[str, list[dict[str, str]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    all_rows = sum(splits.values(), [])
    text = f"""# Dataset Split Report

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

- Total accepted files split: {len(all_rows)}

{split_section("Train", splits["train"])}
{split_section("Validation", splits["validation"])}
{split_section("Test", splits["test"])}
## What This Means

The training split is what the model learns from.

The validation split is what we use while tuning the model.

The test split is what we keep for honest final evaluation.

The next step is feature extraction. We will convert these split files into log-mel spectrogram features so the CNN and CNN + LSTM models can learn real-vs-cloned voice patterns.
"""
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Create VoiceGuard train/validation/test splits.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to the aiworks folder.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    filtered_manifest = root / "manifests" / "filtered_manifest.csv"
    split_dir = root / "splits"
    report_path = root / "reports" / "split_report.md"

    rows = accepted_rows(read_csv(filtered_manifest))
    splits = create_splits(rows)

    write_csv(split_dir / "train.csv", splits["train"])
    write_csv(split_dir / "validation.csv", splits["validation"])
    write_csv(split_dir / "test.csv", splits["test"])
    write_report(report_path, splits)

    print(f"Accepted rows split: {len(rows)}")
    print(f"Train: {len(splits['train'])}")
    print(f"Validation: {len(splits['validation'])}")
    print(f"Test: {len(splits['test'])}")
    print(f"Wrote: {split_dir / 'train.csv'}")
    print(f"Wrote: {split_dir / 'validation.csv'}")
    print(f"Wrote: {split_dir / 'test.csv'}")
    print(f"Wrote: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
