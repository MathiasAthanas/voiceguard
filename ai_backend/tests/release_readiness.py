"""Run a repeatable local VoiceGuard release-readiness simulation.

This uses held-out AIWorks audio to exercise the same services used by FastAPI.
It does not replace real-device VoIP and cellular-call testing.
"""

import asyncio
import csv
import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List

import numpy as np
import soundfile as sf
from scipy import signal


BACKEND_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_ROOT.parents[1]
AIWORKS_ROOT = PROJECT_ROOT / "aiworks"
REPORT_PATH = BACKEND_ROOT / "docs" / "RELEASE_READINESS_REPORT.md"
JSON_PATH = BACKEND_ROOT / "docs" / "release_readiness_results.json"

sys.path.insert(0, str(BACKEND_ROOT))


@dataclass
class Check:
    name: str
    passed: bool
    details: str
    verdict: str = ""
    primary_similarity: float = -1.0
    secondary_similarity: float = -1.0
    spoof_probability: float = -1.0


def read_pairs() -> List[Dict[str, str]]:
    with (AIWORKS_ROOT / "pairs" / "test_pairs.csv").open(
        "r", newline="", encoding="utf-8"
    ) as handle:
        return list(csv.DictReader(handle))


def select_audio() -> Dict[str, Path]:
    rows = read_pairs()
    same = next(row for row in rows if row["pair_type"] == "same_real")
    speaker = same["speaker_a"]

    clone = next(
        row
        for row in rows
        if row["pair_type"] == "clone_attack" and row["speaker_a"] == speaker
    )
    different = next(
        row
        for row in rows
        if row["pair_type"] == "different_real"
        and row["speaker_a"] != speaker
        and row["speaker_b"] != speaker
    )

    return {
        "enroll_a": Path(same["normalized_path_a"]),
        "enroll_a_feature": Path(same["feature_path_a"]),
        "enroll_b": Path(same["normalized_path_b"]),
        "same_clean": Path(clone["normalized_path_a"]),
        "clone": Path(clone["normalized_path_b"]),
        "different": Path(different["normalized_path_a"]),
    }


def audio_bytes(path: Path) -> bytes:
    return path.read_bytes()


def create_phone_like_audio(source: Path, output: Path) -> None:
    """Approximate narrow-band/noisy call audio while preserving the speaker."""
    audio, sample_rate = sf.read(str(source), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)
    if sample_rate != 16000:
        gcd = np.gcd(sample_rate, 16000)
        audio = signal.resample_poly(audio, 16000 // gcd, sample_rate // gcd)
        sample_rate = 16000

    sos = signal.butter(
        4, [300 / (sample_rate / 2), 3400 / (sample_rate / 2)], btype="bandpass", output="sos"
    )
    filtered = signal.sosfilt(sos, audio).astype(np.float32)
    rng = np.random.default_rng(42)
    noise = rng.normal(0.0, 0.006, size=filtered.shape).astype(np.float32)
    degraded = filtered * 0.72 + noise
    degraded = np.clip(degraded, -1.0, 1.0)
    sf.write(str(output), degraded, sample_rate, subtype="PCM_16")


def result_check(name: str, result: dict, accepted_verdicts: set) -> Check:
    primary = result.get("primary_verification") or {}
    secondary = result.get("secondary_verification") or {}
    verdict = str(result.get("verdict", ""))
    return Check(
        name=name,
        passed=verdict in accepted_verdicts,
        details=str(result.get("message") or result.get("error") or verdict),
        verdict=verdict,
        primary_similarity=float(primary.get("similarity_score", -1.0)),
        secondary_similarity=float(secondary.get("similarity_score", -1.0)),
        spoof_probability=float(result.get("spoof_probability", -1.0)),
    )


def feature_parity_check(audio_path: Path, saved_feature_path: Path) -> Check:
    from app.models.cnn_lstm_voiceguard import audio_to_logmel
    from app.utils.audio_utils import load_audio_from_file

    runtime = audio_to_logmel(load_audio_from_file(str(audio_path))).astype(np.float32)
    saved = np.load(str(saved_feature_path)).astype(np.float32)
    correlation = float(np.corrcoef(runtime.reshape(-1), saved.reshape(-1))[0, 1])
    mean_absolute_error = float(np.mean(np.abs(runtime - saved)))
    return Check(
        "Runtime log-mel matches training features",
        correlation >= 0.995 and mean_absolute_error <= 0.05,
        f"correlation={correlation:.6f}, mean_absolute_error={mean_absolute_error:.6f}",
    )


async def signaling_checks() -> List[Check]:
    from app.api.signaling import AnswerCallRequest, CallUserRequest, EndCallRequest, hub

    caller = "readiness-caller"
    callee = "readiness-callee"
    await hub.register_http(caller)
    await hub.register_http(callee)
    await hub.call_user(CallUserRequest(calleeId=callee, callerId=caller, offer={"sdp": "test"}))

    callee_events = await hub.events(callee, timeout=1)
    incoming = next(
        (event for event in callee_events["events"] if event.get("type") == "incoming_call"),
        None,
    )
    checks = [
        Check(
            "HTTP signaling creates incoming call",
            incoming is not None,
            json.dumps(callee_events["events"]),
        )
    ]
    if incoming:
        room_id = incoming["roomId"]
        await hub.answer_call(AnswerCallRequest(roomId=room_id, callerId=caller, answer={"sdp": "answer"}))
        caller_events = await hub.events(caller, timeout=1)
        answered = any(event.get("type") == "call_answered" for event in caller_events["events"])
        checks.append(Check("HTTP signaling answers call", answered, json.dumps(caller_events["events"])))

        await hub.end_call(EndCallRequest(roomId=room_id, targetUserId=callee))
        end_events = await hub.events(callee, timeout=1)
        ended = any(event.get("type") == "call_ended" for event in end_events["events"])
        checks.append(Check("HTTP signaling ends call", ended, json.dumps(end_events["events"])))

    await hub.unregister(caller)
    await hub.unregister(callee)
    return checks


def write_report(checks: List[Check], samples: Dict[str, Path]) -> None:
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    passed = sum(1 for check in checks if check.passed)
    total = len(checks)
    rows = "\n".join(
        f"| {check.name} | {'PASS' if check.passed else 'FAIL'} | {check.verdict or '-'} | "
        f"{check.primary_similarity:.4f} | {check.secondary_similarity:.4f} | "
        f"{check.spoof_probability:.4f} | {check.details.replace('|', '/')} |"
        for check in checks
    )
    sample_lines = "\n".join(f"- `{name}`: `{path}`" for name, path in samples.items())
    REPORT_PATH.write_text(
        f"""# VoiceGuard Local Release Readiness Report

This report was generated by `tests/release_readiness.py`.

It simulates enrollment and call verification with held-out real, different-speaker,
and cloned audio. It also creates a band-limited noisy sample to approximate phone audio.

## Summary

```text
passed: {passed}
total: {total}
status: {'READY FOR DEVICE TESTING' if passed == total else 'NOT READY - FIX FAILED CHECKS'}
```

## Samples

{sample_lines}

## Checks

| Check | Result | Verdict | ECAPA Similarity | Secondary Similarity | Spoof Probability | Details |
| --- | --- | --- | ---: | ---: | ---: | --- |
{rows}

## Important Limit

This simulation cannot prove that every Android phone cleanly captures the remote caller.
Real-device testing is still required for VoIP and cellular media capture, permissions,
audio routing, echo cancellation, and background behavior.
""",
        encoding="utf-8",
    )
    JSON_PATH.write_text(
        json.dumps([asdict(check) for check in checks], indent=2),
        encoding="utf-8",
    )


def main() -> int:
    samples = select_audio()
    checks: List[Check] = []

    with tempfile.TemporaryDirectory(prefix="voiceguard-readiness-") as temp:
        temp_path = Path(temp)
        voiceprints = temp_path / "voiceprints"
        os.environ["VOICEPRINTS_DIR"] = str(voiceprints)
        os.environ.setdefault("CNN_LSTM_SPOOF_THRESHOLD", "0.32")
        os.environ.setdefault("VERIFICATION_THRESHOLD", "0.55")

        phone_like = temp_path / "phone_like.wav"
        silence = temp_path / "silence.wav"
        create_phone_like_audio(samples["same_clean"], phone_like)
        sf.write(str(silence), np.zeros(16000 * 4, dtype=np.float32), 16000, subtype="PCM_16")
        samples["same_phone_like"] = phone_like
        samples["silence"] = silence

        from app.services.enrollment_service import get_enrollment_service
        from app.services.verification_service import get_verification_service
        from app.utils.embedding_utils import secondary_voiceprint_exists, voiceprint_exists

        checks.append(feature_parity_check(samples["enroll_a"], samples["enroll_a_feature"]))

        enrollment = get_enrollment_service().enroll_contact(
            "readiness-speaker",
            [audio_bytes(samples["enroll_a"]), audio_bytes(samples["enroll_b"])],
            source_quality="high",
        )
        checks.append(
            Check(
                "Enrollment accepts two consistent real samples",
                bool(enrollment.get("success")),
                json.dumps(enrollment, default=str),
            )
        )
        checks.append(
            Check(
                "Enrollment saves ECAPA and secondary voiceprints",
                voiceprint_exists("readiness-speaker")
                and secondary_voiceprint_exists("readiness-speaker"),
                f"primary={voiceprint_exists('readiness-speaker')}, "
                f"secondary={secondary_voiceprint_exists('readiness-speaker')}",
            )
        )

        verifier = get_verification_service()
        clean = verifier.verify("readiness-speaker", audio_bytes(samples["same_clean"]), "remote_speaker", "simulation_clean")
        checks.append(
            result_check(
                "Same speaker clean audio",
                clean,
                {"verified", "verified_high", "secondary_warning", "spoof_suspected"},
            )
        )

        phone = verifier.verify("readiness-speaker", audio_bytes(phone_like), "remote_speaker", "simulation_phone_like")
        checks.append(
            result_check(
                "Same speaker phone-like audio",
                phone,
                {
                    "verified",
                    "verified_high",
                    "secondary_warning",
                    "spoof_suspected",
                    "uncertain",
                },
            )
        )

        different = verifier.verify("readiness-speaker", audio_bytes(samples["different"]), "remote_speaker", "simulation_different")
        checks.append(
            result_check(
                "Different speaker is not authenticated",
                different,
                {"not_verified", "spoof_suspected", "uncertain"},
            )
        )

        clone = verifier.verify("readiness-speaker", audio_bytes(samples["clone"]), "remote_speaker", "simulation_clone")
        checks.append(
            result_check(
                "Clone attack is rejected",
                clone,
                {"spoof_detected", "spoof_suspected", "not_verified", "uncertain"},
            )
        )

        silent = verifier.verify("readiness-speaker", audio_bytes(silence), "remote_speaker", "simulation_silence")
        checks.append(result_check("Silence is skipped", silent, {"silent"}))

        missing = verifier.verify("not-enrolled-contact", audio_bytes(samples["same_clean"]))
        checks.append(result_check("Unknown contact requires enrollment", missing, {"not_enrolled"}))

        checks.extend(asyncio.run(signaling_checks()))
        write_report(checks, samples)

        failed = [check for check in checks if not check.passed]
        print(f"Passed {len(checks) - len(failed)}/{len(checks)} checks")
        for check in checks:
            print(f"{'PASS' if check.passed else 'FAIL'}: {check.name} -> {check.verdict or check.details}")
        print(f"Report: {REPORT_PATH}")
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
