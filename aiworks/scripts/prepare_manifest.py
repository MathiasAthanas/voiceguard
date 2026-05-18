"""
Build the first VoiceGuard AI dataset manifests.

This script does not modify or delete dataset files. It scans datagroup1 and
datagroup2, reads audio metadata where possible, labels each file from the
folder structure, and writes:

  manifests/raw_manifest.csv
  manifests/clean_manifest.csv
  reports/dataset_summary.md
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import os
import statistics
import wave
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable


AUDIO_EXTENSIONS = {".wav", ".mp3", ".amr", ".m4a", ".flac", ".ogg"}
MIN_DURATION_SECONDS = 1.0
MIN_FILE_BYTES = 10_000


@dataclass
class AudioRow:
    path: str
    dataset: str
    speaker_id: str
    label: str
    extension: str
    file_size_bytes: int
    duration_seconds: str
    sample_rate: str
    channels: str
    readable: bool
    usable: bool
    reject_reason: str
    sha1: str


def iter_audio_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS:
            yield path


def infer_dataset(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).parts[0]
    except IndexError:
        return "unknown"


def infer_speaker_id(path: Path, root: Path) -> str:
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        return "unknown"
    return parts[1] if len(parts) > 1 else "unknown"


def infer_label(path: Path) -> str:
    parts = {part.lower() for part in path.parts}
    if "really_voices" in parts:
        return "real"
    if "cloned_voices" in parts:
        return "cloned"
    return "unknown"


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_wav_metadata(path: Path) -> tuple[bool, float | None, int | None, int | None, str]:
    try:
        with wave.open(str(path), "rb") as wav:
            sample_rate = wav.getframerate()
            channels = wav.getnchannels()
            frames = wav.getnframes()
            duration = frames / float(sample_rate or 1)
            return True, duration, sample_rate, channels, ""
    except Exception as exc:
        return False, None, None, None, f"unreadable_wav:{type(exc).__name__}"


def read_audio_metadata(path: Path) -> tuple[bool, float | None, int | None, int | None, str]:
    if path.suffix.lower() == ".wav":
        return read_wav_metadata(path)
    return False, None, None, None, "needs_conversion_before_metadata"


def build_row(path: Path, root: Path) -> AudioRow:
    file_size = path.stat().st_size
    label = infer_label(path)
    readable, duration, sample_rate, channels, metadata_reason = read_audio_metadata(path)
    reject_reasons: list[str] = []

    if label == "unknown":
        reject_reasons.append("unknown_label")
    if path.suffix.lower() != ".wav":
        reject_reasons.append("needs_audio_conversion")
    if file_size < MIN_FILE_BYTES:
        reject_reasons.append("file_too_small")
    if not readable:
        reject_reasons.append(metadata_reason or "unreadable_audio")
    if duration is not None and duration < MIN_DURATION_SECONDS:
        reject_reasons.append("duration_too_short")
    if sample_rate is not None and sample_rate <= 0:
        reject_reasons.append("invalid_sample_rate")
    if channels is not None and channels <= 0:
        reject_reasons.append("invalid_channel_count")

    usable = not reject_reasons

    return AudioRow(
        path=str(path),
        dataset=infer_dataset(path, root),
        speaker_id=infer_speaker_id(path, root),
        label=label,
        extension=path.suffix.lower(),
        file_size_bytes=file_size,
        duration_seconds="" if duration is None else f"{duration:.6f}",
        sample_rate="" if sample_rate is None else str(sample_rate),
        channels="" if channels is None else str(channels),
        readable=readable,
        usable=usable,
        reject_reason=";".join(reject_reasons),
        sha1=sha1_file(path),
    )


def write_csv(path: Path, rows: list[AudioRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(asdict(rows[0]).keys()) if rows else list(AudioRow.__annotations__.keys())
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def count_by(rows: list[AudioRow], *fields: str) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        key = tuple(str(getattr(row, field)) for field in fields)
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def format_counts(counts: dict[tuple[str, ...], int]) -> str:
    if not counts:
        return "No rows found.\n"
    lines = []
    for key, value in counts.items():
        lines.append(f"- {' / '.join(key)}: {value}")
    return "\n".join(lines) + "\n"


def numeric_durations(rows: list[AudioRow]) -> list[float]:
    values = []
    for row in rows:
        if row.duration_seconds:
            values.append(float(row.duration_seconds))
    return values


def write_summary(path: Path, rows: list[AudioRow], clean_rows: list[AudioRow]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    durations = numeric_durations(clean_rows)
    rejected = [row for row in rows if not row.usable]
    duplicate_hashes = {
        key: value
        for key, value in count_by(rows, "sha1").items()
        if value > 1 and key[0]
    }

    duration_summary = "No clean durations available."
    if durations:
        duration_summary = (
            f"- Minimum: {min(durations):.2f}s\n"
            f"- Median: {statistics.median(durations):.2f}s\n"
            f"- Mean: {statistics.mean(durations):.2f}s\n"
            f"- Maximum: {max(durations):.2f}s"
        )

    text = f"""# Dataset Manifest Summary

This report is the first preparation checkpoint for our VoiceGuard AI training work. We are not training yet. We are first making the dataset visible, measurable, and safer to use.

## What We Did

We scanned the audio files in:

```text
datagroup1
datagroup2
```

For each file, we recorded:

```text
path
dataset
speaker/session ID
label
file type
file size
duration
sample rate
channel count
readability
usable/rejected status
rejection reason
file hash
```

## Output Files

```text
manifests/raw_manifest.csv
manifests/clean_manifest.csv
reports/dataset_summary.md
```

The raw manifest keeps every audio file we found. The clean manifest keeps only files that passed this first basic scan.

## Overall Counts

- Total audio files scanned: {len(rows)}
- Files currently usable: {len(clean_rows)}
- Files currently rejected: {len(rejected)}

## Counts By Label

{format_counts(count_by(rows, "label"))}
## Clean Counts By Label

{format_counts(count_by(clean_rows, "label"))}
## Counts By Dataset And Label

{format_counts(count_by(rows, "dataset", "label"))}
## Clean Counts By Dataset And Label

{format_counts(count_by(clean_rows, "dataset", "label"))}
## File Types

{format_counts(count_by(rows, "extension"))}
## Sample Rates In Clean WAV Files

{format_counts(count_by(clean_rows, "sample_rate"))}
## Channel Counts In Clean WAV Files

{format_counts(count_by(clean_rows, "channels"))}
## Duration Summary For Clean Files

{duration_summary}

## Rejection Reasons

{format_counts(count_reject_reasons(rejected))}
## Duplicate Hashes

- Duplicate file hashes found: {len(duplicate_hashes)}

## What This Means

This first scan tells us which files are already safe to use and which files need conversion or repair. Files such as MP3 and AMR are not bad, but they need conversion before they can enter the clean training set. Broken WAV files also need to be inspected or excluded.

The next preparation step is to create normalized audio:

```text
16 kHz
mono
WAV
16-bit PCM
```

After that, we can trim silence, normalize loudness, remove duplicates, split the dataset properly, and extract log-mel spectrogram features for CNN/LSTM training.
"""
    path.write_text(text, encoding="utf-8")


def count_reject_reasons(rows: list[AudioRow]) -> dict[tuple[str, ...], int]:
    counts: dict[tuple[str, ...], int] = {}
    for row in rows:
        reasons = row.reject_reason.split(";") if row.reject_reason else ["unknown"]
        for reason in reasons:
            key = (reason,)
            counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare VoiceGuard dataset manifests.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Path to the aiworks folder.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    manifests_dir = root / "manifests"
    reports_dir = root / "reports"

    rows = [build_row(path, root) for path in iter_audio_files(root)]
    clean_rows = [row for row in rows if row.usable]

    write_csv(manifests_dir / "raw_manifest.csv", rows)
    write_csv(manifests_dir / "clean_manifest.csv", clean_rows)
    write_summary(reports_dir / "dataset_summary.md", rows, clean_rows)

    print(f"Scanned audio files: {len(rows)}")
    print(f"Usable files: {len(clean_rows)}")
    print(f"Rejected files: {len(rows) - len(clean_rows)}")
    print(f"Wrote: {manifests_dir / 'raw_manifest.csv'}")
    print(f"Wrote: {manifests_dir / 'clean_manifest.csv'}")
    print(f"Wrote: {reports_dir / 'dataset_summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
