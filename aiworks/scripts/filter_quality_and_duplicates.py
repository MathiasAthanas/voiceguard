"""
Filter normalized VoiceGuard audio for duplicates and basic speech quality.

This script reads manifests/normalized_manifest.csv and creates:

  manifests/filtered_manifest.csv
  reports/filtering_report.md

It does not delete audio files. It marks which normalized files are accepted
for splitting/training and explains why rejected files were rejected.
"""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import asdict, dataclass
from pathlib import Path

import librosa
import numpy as np


MIN_DURATION_SECONDS = 1.0
MIN_RMS_DBFS = -45.0
MIN_ACTIVE_RATIO = 0.20


@dataclass
class FilteredRow:
    normalized_path: str
    source_path: str
    dataset: str
    speaker_id: str
    label: str
    duration_seconds: str
    rms_dbfs: str
    peak: str
    active_ratio: str
    source_extension: str
    source_sha1: str
    normalized_sha1: str
    accepted: bool
    reject_reason: str


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[FilteredRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(asdict(rows[0]).keys()) if rows else list(FilteredRow.__annotations__.keys())
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def safe_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def quality_metrics(path: Path) -> tuple[float, float, float, float]:
    audio, sr = librosa.load(str(path), sr=None, mono=True)
    if audio.size == 0 or sr <= 0:
        raise ValueError("empty_audio")

    duration = audio.size / float(sr)
    rms = float(np.sqrt(np.mean(np.square(audio), dtype=np.float64)))
    rms_dbfs = 20.0 * math.log10(max(rms, 1e-12))
    peak = float(np.max(np.abs(audio)))

    intervals = librosa.effects.split(audio, top_db=35)
    active_samples = sum(int(end - start) for start, end in intervals)
    active_ratio = active_samples / float(audio.size)

    return duration, rms_dbfs, peak, active_ratio


def build_rows(normalized_rows: list[dict[str, str]]) -> list[FilteredRow]:
    rows: list[FilteredRow] = []
    seen_hashes: set[str] = set()

    for row in normalized_rows:
        reject_reasons: list[str] = []
        path = Path(row.get("normalized_path", ""))
        normalized_sha1 = row.get("normalized_sha1", "")

        if row.get("status") != "normalized":
            reject_reasons.append(row.get("reject_reason") or "not_normalized")

        if not path.exists():
            reject_reasons.append("normalized_file_missing")

        if normalized_sha1 and normalized_sha1 in seen_hashes:
            reject_reasons.append("duplicate_normalized_audio")
        elif normalized_sha1:
            seen_hashes.add(normalized_sha1)

        duration = safe_float(row.get("normalized_duration_seconds", ""))
        rms_dbfs = 0.0
        peak = 0.0
        active_ratio = 0.0

        if not reject_reasons:
            try:
                duration, rms_dbfs, peak, active_ratio = quality_metrics(path)
                if duration < MIN_DURATION_SECONDS:
                    reject_reasons.append("duration_too_short")
                if rms_dbfs < MIN_RMS_DBFS:
                    reject_reasons.append("too_quiet")
                if peak <= 1e-5:
                    reject_reasons.append("near_silent")
                if active_ratio < MIN_ACTIVE_RATIO:
                    reject_reasons.append("low_speech_activity")
            except Exception as exc:
                reject_reasons.append(f"quality_check_failed:{type(exc).__name__}")

        rows.append(
            FilteredRow(
                normalized_path=str(path),
                source_path=row.get("source_path", ""),
                dataset=row.get("dataset", ""),
                speaker_id=row.get("speaker_id", ""),
                label=row.get("label", ""),
                duration_seconds=f"{duration:.6f}" if duration else "",
                rms_dbfs=f"{rms_dbfs:.3f}" if rms_dbfs else "",
                peak=f"{peak:.6f}" if peak else "",
                active_ratio=f"{active_ratio:.6f}" if active_ratio else "",
                source_extension=row.get("source_extension", ""),
                source_sha1=row.get("source_sha1", ""),
                normalized_sha1=normalized_sha1,
                accepted=not reject_reasons,
                reject_reason=";".join(reject_reasons),
            )
        )

    return rows


def count_by(rows: list[FilteredRow], *fields: str) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        key = tuple(str(getattr(row, field)) for field in fields)
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def count_reject_reasons(rows: list[FilteredRow]) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        if row.accepted:
            continue
        for reason in row.reject_reason.split(";"):
            key = (reason or "unknown",)
            counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def format_counts(counts: dict[tuple[str, ...], int]) -> str:
    if not counts:
        return "No rows found.\n"
    return "\n".join(f"- {' / '.join(key)}: {value}" for key, value in counts.items()) + "\n"


def write_report(path: Path, rows: list[FilteredRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    accepted = [row for row in rows if row.accepted]
    rejected = [row for row in rows if not row.accepted]

    text = f"""# Filtering Report

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

- Rows checked: {len(rows)}
- Accepted for splitting: {len(accepted)}
- Rejected after filtering: {len(rejected)}

## Accepted Files By Label

{format_counts(count_by(accepted, "label"))}
## Accepted Files By Dataset And Label

{format_counts(count_by(accepted, "dataset", "label"))}
## Rejection Reasons

{format_counts(count_reject_reasons(rows))}
## What This Means

This step does not delete the original data. It simply tells the training pipeline which normalized files are safer to use.

The next step is to split accepted files into:

```text
train
validation
test
```

We should split by speaker/session as much as possible so our evaluation is more honest and does not simply reward memorization.
"""
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Filter normalized VoiceGuard audio.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to the aiworks folder.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    input_manifest = root / "manifests" / "normalized_manifest.csv"
    output_manifest = root / "manifests" / "filtered_manifest.csv"
    report_path = root / "reports" / "filtering_report.md"

    normalized_rows = read_csv(input_manifest)
    rows = build_rows(normalized_rows)
    write_csv(output_manifest, rows)
    write_report(report_path, rows)

    accepted_count = sum(1 for row in rows if row.accepted)
    print(f"Rows checked: {len(rows)}")
    print(f"Accepted for splitting: {accepted_count}")
    print(f"Rejected after filtering: {len(rows) - accepted_count}")
    print(f"Wrote: {output_manifest}")
    print(f"Wrote: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
