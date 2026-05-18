"""
Normalize VoiceGuard training audio into one clean format.

This script reads manifests/raw_manifest.csv, attempts to load each labeled
audio file, trims long silence, normalizes peak level, and writes a prepared
16 kHz mono WAV copy.

Outputs:
  prepared_audio/
  manifests/normalized_manifest.csv
  reports/normalization_report.md
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
from dataclasses import asdict, dataclass
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf


TARGET_SAMPLE_RATE = 16_000
MIN_DURATION_SECONDS = 1.0
TRIM_TOP_DB = 35
PEAK_TARGET = 0.95


@dataclass
class NormalizedRow:
    source_path: str
    normalized_path: str
    dataset: str
    speaker_id: str
    label: str
    source_extension: str
    source_file_size_bytes: int
    source_duration_seconds: str
    normalized_duration_seconds: str
    target_sample_rate: int
    channels: int
    status: str
    reject_reason: str
    source_sha1: str
    normalized_sha1: str


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[NormalizedRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(asdict(rows[0]).keys()) if rows else list(NormalizedRow.__annotations__.keys())
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_float(value: str) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def output_path(prepared_root: Path, row: dict[str, str]) -> Path:
    source = Path(row["path"])
    digest = row.get("sha1", "")[:10] or hashlib.sha1(str(source).encode("utf-8")).hexdigest()[:10]
    filename = f"{source.stem}_{digest}.wav"
    return prepared_root / row["dataset"] / row["speaker_id"] / row["label"] / filename


def load_and_prepare_audio(path: Path) -> tuple[np.ndarray, float]:
    audio, _ = librosa.load(str(path), sr=TARGET_SAMPLE_RATE, mono=True)
    if audio.size == 0:
        raise ValueError("empty_audio")

    audio, _ = librosa.effects.trim(audio, top_db=TRIM_TOP_DB)
    if audio.size == 0:
        raise ValueError("silent_after_trim")

    audio = audio.astype(np.float32)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if not math.isfinite(peak) or peak <= 1e-6:
        raise ValueError("near_silent_audio")

    audio = (audio / peak) * PEAK_TARGET
    duration = audio.size / float(TARGET_SAMPLE_RATE)
    if duration < MIN_DURATION_SECONDS:
        raise ValueError("duration_too_short_after_trim")

    return audio, duration


def normalize_row(row: dict[str, str], prepared_root: Path) -> NormalizedRow:
    source = Path(row["path"])
    source_duration = row.get("duration_seconds", "")
    target = output_path(prepared_root, row)

    if row.get("label") not in {"real", "cloned"}:
        return rejected_row(row, target, "unknown_label")

    if int(row.get("file_size_bytes", "0") or 0) < 10_000:
        return rejected_row(row, target, "file_too_small")

    try:
        audio, normalized_duration = load_and_prepare_audio(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(target), audio, TARGET_SAMPLE_RATE, subtype="PCM_16")
        return NormalizedRow(
            source_path=str(source),
            normalized_path=str(target),
            dataset=row["dataset"],
            speaker_id=row["speaker_id"],
            label=row["label"],
            source_extension=row["extension"],
            source_file_size_bytes=int(row["file_size_bytes"]),
            source_duration_seconds=source_duration,
            normalized_duration_seconds=f"{normalized_duration:.6f}",
            target_sample_rate=TARGET_SAMPLE_RATE,
            channels=1,
            status="normalized",
            reject_reason="",
            source_sha1=row.get("sha1", ""),
            normalized_sha1=sha1_file(target),
        )
    except Exception as exc:
        reason = str(exc) or type(exc).__name__
        return rejected_row(row, target, reason)


def rejected_row(row: dict[str, str], target: Path, reason: str) -> NormalizedRow:
    return NormalizedRow(
        source_path=row.get("path", ""),
        normalized_path=str(target),
        dataset=row.get("dataset", "unknown"),
        speaker_id=row.get("speaker_id", "unknown"),
        label=row.get("label", "unknown"),
        source_extension=row.get("extension", ""),
        source_file_size_bytes=int(row.get("file_size_bytes", "0") or 0),
        source_duration_seconds=row.get("duration_seconds", ""),
        normalized_duration_seconds="",
        target_sample_rate=TARGET_SAMPLE_RATE,
        channels=1,
        status="rejected",
        reject_reason=reason.replace("\n", " ")[:300],
        source_sha1=row.get("sha1", ""),
        normalized_sha1="",
    )


def count_by(rows: list[NormalizedRow], *fields: str) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        key = tuple(str(getattr(row, field)) for field in fields)
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def format_counts(counts: dict[tuple[str, ...], int]) -> str:
    if not counts:
        return "No rows found.\n"
    return "\n".join(f"- {' / '.join(key)}: {value}" for key, value in counts.items()) + "\n"


def duration_summary(rows: list[NormalizedRow]) -> str:
    values = [safe_float(row.normalized_duration_seconds) for row in rows if row.status == "normalized"]
    durations = [value for value in values if value is not None]
    if not durations:
        return "No normalized durations available."
    return (
        f"- Minimum: {min(durations):.2f}s\n"
        f"- Median: {float(np.median(durations)):.2f}s\n"
        f"- Mean: {float(np.mean(durations)):.2f}s\n"
        f"- Maximum: {max(durations):.2f}s"
    )


def write_report(path: Path, rows: list[NormalizedRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = [row for row in rows if row.status == "normalized"]
    rejected = [row for row in rows if row.status != "normalized"]
    text = f"""# Audio Normalization Report

This report is the second preparation checkpoint for our VoiceGuard AI training work. In this step, we started turning the raw dataset into consistent training audio.

## What We Did Together

We read:

```text
manifests/raw_manifest.csv
```

Then we attempted to load each labeled audio file, trim long silence, normalize the peak level, and save a clean copy as:

```text
16 kHz
mono
WAV
16-bit PCM
```

The normalized audio is stored in:

```text
prepared_audio
```

The updated manifest is:

```text
manifests/normalized_manifest.csv
```

## Overall Result

- Files attempted: {len(rows)}
- Files normalized: {len(normalized)}
- Files rejected during normalization: {len(rejected)}

## Normalized Files By Label

{format_counts(count_by(normalized, "label"))}
## Normalized Files By Dataset And Label

{format_counts(count_by(normalized, "dataset", "label"))}
## Source File Types That Were Normalized

{format_counts(count_by(normalized, "source_extension"))}
## Rejections By Reason

{format_counts(count_by(rejected, "reject_reason"))}
## Normalized Duration Summary

{duration_summary(rows)}

## What This Means

This step gives us one consistent audio format for model preparation. That is important because the CNN and LSTM should learn voice and clone patterns, not file format differences.

This is still not the final training set. The next stage should remove duplicates, check speech quality more deeply, split the dataset into train/validation/test, and then extract log-mel spectrogram features.
"""
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize VoiceGuard AI audio files.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to the aiworks folder.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional limit for quick test runs.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    manifest_path = root / "manifests" / "raw_manifest.csv"
    prepared_root = root / "prepared_audio"
    output_manifest = root / "manifests" / "normalized_manifest.csv"
    report_path = root / "reports" / "normalization_report.md"

    raw_rows = read_csv(manifest_path)
    if args.limit is not None:
        raw_rows = raw_rows[: args.limit]

    rows = []
    for index, row in enumerate(raw_rows, start=1):
        rows.append(normalize_row(row, prepared_root))
        if index % 250 == 0:
            print(f"Processed {index}/{len(raw_rows)}")

    write_csv(output_manifest, rows)
    write_report(report_path, rows)

    normalized_count = sum(1 for row in rows if row.status == "normalized")
    print(f"Attempted files: {len(rows)}")
    print(f"Normalized files: {normalized_count}")
    print(f"Rejected files: {len(rows) - normalized_count}")
    print(f"Wrote: {output_manifest}")
    print(f"Wrote: {report_path}")
    print(f"Wrote audio under: {prepared_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
